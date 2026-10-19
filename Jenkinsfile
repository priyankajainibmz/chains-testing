// Jenkinsfile — Tekton Chains Verification Pipeline
// Mirrors chains.sh end-to-end, adapted for Jenkins declarative pipeline.
//
// Required Jenkins credentials (Manage Jenkins → Credentials):
//   ocp-credentials   → "Username with password" containing OCP kubeadmin creds
//   dockerhub-creds   → "Username with password" for docker.io push access
//
// Required Jenkins parameters (filled via UI or upstream trigger):
//   OCP_URL, PROJECT, IMAGE

pipeline {
    agent any

    parameters {
        string(
            name: 'OCP_URL',
            defaultValue: '',
            description: 'OpenShift API URL e.g. https://api.mycluster.example.com:6443'
        )
        string(
            name: 'PROJECT',
            defaultValue: 'chains-test',
            description: 'OpenShift project/namespace to create for this test run'
        )
        string(
            name: 'IMAGE',
            defaultValue: 'docker.io/myorg/kaniko-chains',
            description: 'Fully-qualified image to build and verify'
        )
    }

    environment {
        OCP_CREDS    = credentials('ocp-credentials')    // OCP_CREDS_USR / OCP_CREDS_PSW
        ARCH         = sh(script: 'uname -m | sed s/x86_64/amd64/', returnStdout: true).trim()
        WORKDIR      = sh(script: "echo /tmp/chains-${params.PROJECT}-\$(uname -m)", returnStdout: true).trim()
        KANIKO_IMAGE = 'gcr.io/kaniko-project/executor:v1.9.0'
        // ~/bin is writable by the jenkins user and prepended to PATH
        // so tools installed there are found in all subsequent stages
        TOOLS_DIR    = "${env.HOME}/bin"
        PATH         = "${env.HOME}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:${env.PATH}"
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 90, unit: 'MINUTES')
        disableConcurrentBuilds()
        timestamps()
    }

    stages {

        // -------------------------------------------------------------------
        stage('Validate Parameters') {
        // -------------------------------------------------------------------
            steps {
                script {
                    if (!params.OCP_URL?.trim())  error("OCP_URL is required")
                    if (!params.PROJECT?.trim())  error("PROJECT is required")
                    if (!params.IMAGE?.trim())    error("IMAGE is required")
                    echo "OCP_URL : ${params.OCP_URL}"
                    echo "PROJECT : ${params.PROJECT}"
                    echo "IMAGE   : ${params.IMAGE}"
                }
            }
        }

        // -------------------------------------------------------------------
        stage('Prerequisites') {
        // -------------------------------------------------------------------
            steps {
                sh '''
                    echo "PATH: $PATH"

                    # Auto-install tkn into ~/bin (user-writable, no sudo needed).
                    # tkn filenames use uname -m directly: x86_64, s390x, aarch64
                    # (NOT amd64 — do not convert)
                    if ! type tkn >/dev/null 2>&1; then
                        echo "tkn not found — installing v0.37.0 to ${TOOLS_DIR}..."
                        mkdir -p "${TOOLS_DIR}"
                        TKN_ARCH=$(uname -m)
                        curl -fsSL "https://github.com/tektoncd/cli/releases/download/v0.37.0/tkn_0.37.0_Linux_${TKN_ARCH}.tar.gz" \
                          | tar -xz -C "${TOOLS_DIR}" tkn
                        chmod 755 "${TOOLS_DIR}/tkn"
                        echo "tkn installed: $(tkn version)"
                    fi

                    # Verify all required tools are present
                    MISSING=0
                    for tool in oc tkn curl jq git file; do
                        if type "$tool" >/dev/null 2>&1; then
                            echo "  ✓ $tool -> $(which $tool)"
                        else
                            echo "  ✗ $tool NOT FOUND"
                            MISSING=1
                        fi
                    done
                    if [ $MISSING -ne 0 ]; then
                        echo "ERROR: one or more required tools are missing."
                        exit 1
                    fi
                    echo "All prerequisites satisfied."
                '''
            }
        }

        // -------------------------------------------------------------------
        stage('OCP Login') {
        // -------------------------------------------------------------------
            steps {
                sh '''
                    oc login "${OCP_URL}" \
                        -u "${OCP_CREDS_USR}" \
                        -p "${OCP_CREDS_PSW}" \
                        --insecure-skip-tls-verify=true

                    oc new-project "${PROJECT}" || oc project "${PROJECT}"
                    echo "Project ${PROJECT} created or switched successfully."

                    sleep 10

                    if ! oc get pods -n openshift-operators 2>/dev/null \
                            | grep -q "openshift-pipelines-operator"; then
                        echo "ERROR: Tekton Pipelines not installed"
                        exit 1
                    fi
                    echo "Tekton Pipelines is installed."
                '''
            }
        }

        // -------------------------------------------------------------------
        stage('Install Chains + Download Tools') {
        // -------------------------------------------------------------------
            steps {
                sh '''
                    mkdir -p "${WORKDIR}" && cd "${WORKDIR}"

                    echo "Downloading cosign v2.2.4 and rekor-cli for arch: ${ARCH}"
                    curl -fSL "https://github.com/sigstore/cosign/releases/download/v2.2.4/cosign-linux-${ARCH}" -o cosign
                    curl -fSL "https://github.com/sigstore/rekor/releases/download/v1.0.1/rekor-cli-linux-${ARCH}" -o rekor-cli
                    chmod 755 cosign rekor-cli

                    for bin in cosign rekor-cli; do
                        if ! file "./${bin}" | grep -q "ELF"; then
                            echo "ERROR: ${bin} is not a valid ELF binary"
                            exit 1
                        fi
                        echo "  ✓ ${bin} is a valid ELF binary"
                    done

                    cat <<EOF | oc apply -f -
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonChain
metadata:
  name: chain
spec:
  targetNamespace: openshift-pipelines
EOF

                    echo "Waiting for Tekton Chains to become ready..."
                    while true; do
                        STATUS=$(oc get tektonchains.operator.tekton.dev -o json 2>/dev/null \
                            | jq -r '.items[].status.conditions[] | select(.type=="Ready") | .status' || true)
                        [ "$STATUS" = "True" ] && echo "Tekton Chains ready." && break
                        echo "  Not ready yet, retrying in 30s..."
                        sleep 30
                    done
                '''
            }
        }

        // -------------------------------------------------------------------
        stage('Configure Chains') {
        // -------------------------------------------------------------------
            steps {
                // Use withCredentials to get a temp file path for the Docker config.
                // Requires a Jenkins "Secret file" credential named 'dockerhub-config'
                // containing the contents of ~/.docker/config.json
                withCredentials([file(credentialsId: 'dockerhub-config', variable: 'DOCKER_CONFIG_FILE')]) {
                    // Write configure script to disk so Groovy never parses the
                    // shell syntax (backslashes, single-quotes inside heredocs, etc.)
                    writeFile file: 'configure_chains.sh', text: """#!/bin/bash
set -euo pipefail
cd "\${WORKDIR}"

# Check signing-secrets — generate key pair if secret is missing OR has no data
rm -f cosign.pub
SECRET_DATA=\$(oc get secret signing-secrets -n openshift-pipelines \\
    -o jsonpath='{.data}' 2>/dev/null || echo "")
if [ "\${SECRET_DATA}" = "{}" ] || [ -z "\${SECRET_DATA}" ]; then
    echo "signing-secrets is empty or missing — generating new cosign key pair..."
    COSIGN_PASSWORD="" ./cosign generate-key-pair \\
        k8s://openshift-pipelines/signing-secrets
    echo "Restarting Chains controller to pick up new key..."
    oc rollout restart deployment/tekton-chains-controller -n openshift-pipelines
    oc rollout status deployment/tekton-chains-controller -n openshift-pipelines --timeout=120s
    echo "Waiting 15s for controller reconciler to initialise with new key..."
    sleep 15
fi
# Now extract the public key (must exist after generate-key-pair)
oc get secret signing-secrets -n openshift-pipelines \\
    -o 'jsonpath={.data.cosign\\.pub}' | base64 -d > cosign.pub
if [ ! -s cosign.pub ]; then
    echo "ERROR: cosign.pub still empty after key generation — cannot continue."
    exit 1
else
    echo "cosign.pub extracted from signing-secrets."
fi

# Registry credentials — use the file Jenkins wrote from the 'dockerhub-config' credential
DOCKER_CONFIG_FILE="\${DOCKER_CONFIG_FILE}"
oc delete secret regcred -n "\${PROJECT}" --ignore-not-found
oc create secret generic regcred \\
    --from-file=.dockerconfigjson="\${DOCKER_CONFIG_FILE}" \\
    --type=kubernetes.io/dockerconfigjson \\
    -n "\${PROJECT}"

# Wait for pipeline SA (created by Tekton operator after project creation)
echo "Waiting for pipeline serviceaccount..."
WAIT=0
until oc get serviceaccount pipeline -n "\${PROJECT}" &>/dev/null; do
    sleep 5; WAIT=\$((WAIT+5))
    [ \$WAIT -ge 60 ] && echo "ERROR: pipeline SA not found" && exit 1
done
oc patch serviceaccount pipeline -n "\${PROJECT}" \\
    -p '{"imagePullSecrets":[{"name":"regcred"}]}'

oc delete secret chains-docker-hub -n "\${PROJECT}" --ignore-not-found
oc create secret generic chains-docker-hub \\
    --from-file=config.json="\${DOCKER_CONFIG_FILE}" \\
    -n "\${PROJECT}"

oc patch configmap chains-config -n openshift-pipelines \\
    -p='{"data":{"artifacts.taskrun.format":"in-toto","artifacts.taskrun.storage":"oci","transparency.enabled":"true"}}'
echo "Waiting 10s for Chains controller to pick up configmap changes..."
sleep 10
"""
                    sh 'bash configure_chains.sh'
                }
            }
        }

        // -------------------------------------------------------------------
        stage('Build Image (Kaniko)') {
        // -------------------------------------------------------------------
            steps {
                sh '''
                    cd "${WORKDIR}"

                    if [ -d chains ]; then
                        git -C chains pull
                    else
                        git clone https://github.com/tektoncd/chains.git
                    fi
                    sleep 5
                    oc apply -f chains/examples/kaniko/kaniko.yaml

                    echo "Starting kaniko-chains TaskRun..."
                    tkn task start \
                        --param=IMAGE="${IMAGE}" \
                        --param=BUILDER_IMAGE="${KANIKO_IMAGE}" \
                        --use-param-defaults \
                        --workspace name=source,emptyDir="" \
                        --workspace name=dockerconfig,secret=chains-docker-hub \
                        -n "${PROJECT}" \
                        kaniko-chains \
                        --showlog
                '''
            }
        }

        // -------------------------------------------------------------------
        stage('Verify Chains') {
        // -------------------------------------------------------------------
            steps {
                // Write the verify logic to a shell script file so Groovy never
                // parses the shell syntax (backslashes, single-quotes, etc.)
                writeFile file: 'verify_chains.sh', text: '''#!/bin/bash
set -euo pipefail
PROJECT="$1"
IMAGE="$2"
WORKDIR="$3"
cd "${WORKDIR}"

# Get last TaskRun name
TR_NAME=$(tkn tr list -n "${PROJECT}" --limit 1 -o jsonpath="{.items[0].metadata.name}")
echo "Last TaskRun: ${TR_NAME}"

# Wait for TaskRun to fully succeed
echo "Waiting for TaskRun to reach Succeeded state..."
ELAPSED=0
while true; do
    STATUS=$(oc get taskrun "${TR_NAME}" -n "${PROJECT}" \
        -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)
    [ "$STATUS" = "True" ] && echo "TaskRun Succeeded." && break
    [ "$STATUS" = "False" ] && echo "ERROR: TaskRun Failed." && exit 1
    [ $ELAPSED -ge 120 ] && echo "ERROR: Timed out waiting." && exit 1
    sleep 5; ELAPSED=$((ELAPSED+5))
done

# Get image digest from TaskRun results
TR_JSON=$(oc get taskrun "${TR_NAME}" -n "${PROJECT}" -o json)
IMAGE_DIGEST=$(echo "${TR_JSON}" \
    | jq -r '.status.results[] | select(.name=="IMAGE_DIGEST") | .value' 2>/dev/null || true)
[ -z "$IMAGE_DIGEST" ] && IMAGE_DIGEST=$(echo "${TR_JSON}" \
    | jq -r '.status.taskResults[] | select(.name=="IMAGE_DIGEST") | .value' 2>/dev/null || true)
echo "IMAGE_DIGEST: ${IMAGE_DIGEST}"
IMAGE_BY_DIGEST="${IMAGE}@${IMAGE_DIGEST}"

# Poll for chains.tekton.dev/signed: true
echo "Waiting for Chains to sign the image..."
WAIT=0
while true; do
    SIGNED=$(oc get taskrun "${TR_NAME}" -n "${PROJECT}" \
        -o jsonpath='{.metadata.annotations.chains\\.tekton\\.dev/signed}' 2>/dev/null || true)
    [ "$SIGNED" = "true" ] && echo "Chains signed the TaskRun." && break
    [ $WAIT -ge 180 ] && echo "ERROR: Timed out waiting for signing." && exit 1
    echo "  Not signed yet... (${WAIT}s)"; sleep 10; WAIT=$((WAIT+10))
done

# Confirm an attestation actually exists in the OCI registry.
# If the Chains controller had no signing key, it marks signed=true but stores nothing.
echo "Checking attestation exists in OCI registry..."
ATT_CHECK=$(./cosign download attestation "${IMAGE_BY_DIGEST}" 2>&1 || true)
if echo "${ATT_CHECK}" | grep -qi "error\|no attestation\|not found"; then
    echo "ERROR: No attestation found in OCI registry for ${IMAGE_BY_DIGEST}"
    echo "The Chains controller likely had no signing key when it processed this TaskRun."
    echo "cosign output: ${ATT_CHECK}"
    echo ""
    echo "Check controller logs:"
    oc logs -n openshift-pipelines -l app=tekton-chains-controller --tail=20 || true
    exit 1
fi
echo "Attestation found in OCI registry."

# Extract the actual signing key from Rekor REST API
TR_JSON=$(oc get taskrun "${TR_NAME}" -n "${PROJECT}" -o json)
REKOR_URL=$(echo "${TR_JSON}" \
    | jq -r '.metadata.annotations["chains.tekton.dev/transparency"] // empty')
LOG_INDEX=$(echo "${REKOR_URL}" | cut -d= -f2)
echo "Rekor transparency URL: ${REKOR_URL:-<none>}"
echo "Log index: ${LOG_INDEX:-<none>}"

if [ -n "$LOG_INDEX" ]; then
    echo "Fetching Rekor entry from rekor.sigstore.dev..."
    # Separate stderr so verbose/error output does not corrupt the JSON
    REKOR_JSON=$(curl -fsSL \
        "https://rekor.sigstore.dev/api/v1/log/entries?logIndex=${LOG_INDEX}" \
        2>/tmp/rekor_curl_err || true)
    if [ -z "$REKOR_JSON" ]; then
        echo "WARNING: Empty/failed response from Rekor."
        echo "curl error: $(cat /tmp/rekor_curl_err)"
    else
        echo "Rekor response (first 300 chars): $(echo "${REKOR_JSON}" | head -c 300)"
        REKOR_KEY=$(echo "${REKOR_JSON}" \
            | jq -r '.[].body' 2>/dev/null | base64 -d 2>/dev/null \
            | jq -r '.spec.signatures[0].verifier' 2>/dev/null | base64 -d 2>/dev/null || true)
        if echo "${REKOR_KEY}" | grep -q "BEGIN PUBLIC KEY"; then
            echo "${REKOR_KEY}" > cosign.pub
            echo "cosign.pub updated from Rekor entry."
        else
            echo "WARNING: Could not extract public key from Rekor response (unexpected format)."
        fi
    fi
else
    echo "WARNING: No Rekor transparency annotation found on TaskRun."
fi

# If cosign.pub is still empty, extract the signing cert from the OCI attestation directly.
# cosign download attestation embeds the signing cert in the DSSE envelope.
if [ ! -s cosign.pub ]; then
    echo "cosign.pub is empty — attempting to extract signing cert from OCI attestation..."
    ATT_JSON=$(./cosign download attestation "${IMAGE_BY_DIGEST}" 2>/dev/null | head -1 || true)
    if [ -n "$ATT_JSON" ]; then
        # The DSSE envelope payload has the cert in the signatures[].cert field (base64 PEM)
        CERT=$(echo "${ATT_JSON}" | jq -r '.signatures[0].cert // empty' 2>/dev/null || true)
        if [ -n "$CERT" ]; then
            echo "${CERT}" | base64 -d > signing.crt 2>/dev/null || echo "${CERT}" > signing.crt
            echo "Extracted signing cert from OCI attestation."
            # Extract public key from cert
            openssl x509 -pubkey -noout -in signing.crt > cosign.pub 2>/dev/null || true
            if [ -s cosign.pub ]; then
                echo "cosign.pub extracted from signing cert via openssl."
            fi
        fi
    fi
fi

echo "cosign.pub in use:"; cat cosign.pub

if [ ! -s cosign.pub ]; then
    echo "ERROR: cosign.pub is empty — cannot verify attestation without a public key."
    echo "Possible causes:"
    echo "  1. rekor.sigstore.dev is not reachable from this Jenkins agent"
    echo "  2. signing-secrets in the cluster has no data (shared cluster key rotation)"
    echo "  3. The OCI attestation does not embed a cert (key-based signing was used)"
    echo ""
    echo "TaskRun annotations for debugging:"
    oc get taskrun "${TR_NAME}" -n "${PROJECT}" \
        -o jsonpath='{.metadata.annotations}' | jq . || true
    exit 1
fi

# cosign verify-attestation
echo "--- cosign verify-attestation ---"
if ./cosign verify-attestation --key ./cosign.pub "${IMAGE_BY_DIGEST}" --type slsaprovenance; then
    echo "Attestation verified (slsaprovenance)."
elif ./cosign verify-attestation --key ./cosign.pub "${IMAGE_BY_DIGEST}" --type slsaprovenance02; then
    echo "Attestation verified (slsaprovenance02)."
else
    echo "ERROR: Attestation verification FAILED."
    exit 1
fi

# Rekor log entry via REST API
echo "--- rekor transparency log ---"
if [ -n "$LOG_INDEX" ]; then
    curl -s "https://rekor.sigstore.dev/api/v1/log/entries?logIndex=${LOG_INDEX}" \
        | jq -r '.[].body' | base64 -d \
        | jq '{kind,apiVersion,payloadHash:.spec.payloadHash,envelopeHash:.spec.envelopeHash}'
    echo "Rekor log entry verified."
fi
'''
                sh "chmod +x verify_chains.sh && bash verify_chains.sh '${params.PROJECT}' '${params.IMAGE}' '${env.WORKDIR}'"
            }
        }
    }

    // -----------------------------------------------------------------------
    post {
        always {
            sh '''
                echo "=== Cleanup ==="
                oc delete all --all -n "${PROJECT}" --grace-period=0 || true
                oc delete project "${PROJECT}" --grace-period=0 || true
                ELAPSED=0
                while oc get project "${PROJECT}" &>/dev/null; do
                    sleep 5; ELAPSED=$((ELAPSED+5))
                    [ $ELAPSED -ge 120 ] && echo "WARNING: project deletion timed out" && break
                done
                oc delete tektonchains.operator.tekton.dev/chain --ignore-not-found || true
                oc delete secret signing-secrets -n openshift-pipelines --ignore-not-found || true
                tkn taskrun delete --all -f -n "${PROJECT}" 2>/dev/null || true
                rm -rf "${WORKDIR}"
                echo "Cleanup done."
            '''
        }
        success { echo "✅ Chains verification PASSED." }
        failure { echo "❌ Chains verification FAILED." }
    }
}
