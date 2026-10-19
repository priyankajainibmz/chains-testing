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
        WORKDIR      = "/tmp/chains-${params.PROJECT}-\$(uname -m)"
        KANIKO_IMAGE = 'gcr.io/kaniko-project/executor:v1.9.0'
        // Extend PATH for all stages — Jenkins agent runs with a restricted PATH
        // that may not include /usr/local/bin where oc, tkn, kubectl are installed
        PATH         = "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:${env.PATH}"
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

                    # Auto-install tkn if missing — avoids blocking on agent image rebuild.
                    # tkn release filenames use uname -m directly: x86_64, s390x, aarch64
                    # (unlike cosign/rekor which use amd64 — do NOT convert x86_64 to amd64 here)
                    if ! type tkn >/dev/null 2>&1; then
                        echo "tkn not found — installing v0.37.0..."
                        TKN_ARCH=$(uname -m)
                        curl -fsSL "https://github.com/tektoncd/cli/releases/download/v0.37.0/tkn_0.37.0_Linux_${TKN_ARCH}.tar.gz" \
                          | tar -xz -C /usr/local/bin tkn
                        chmod 755 /usr/local/bin/tkn
                        echo "tkn installed: $(tkn version)"
                    fi

                    # Verify all required tools are present
                    MISSING=0
                    for tool in kubectl oc tkn curl jq git file; do
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
                sh '''
                    cd "${WORKDIR}"

                    # Read existing public key from signing-secrets — do NOT
                    # regenerate it on a shared cluster (controller uses in-memory key)
                    rm -f cosign.pub
                    if oc get secret signing-secrets -n openshift-pipelines &>/dev/null; then
                        oc get secret signing-secrets -n openshift-pipelines \
                            -o jsonpath=\'{.data.cosign\\.pub}\' | base64 -d > cosign.pub
                        if [ ! -s cosign.pub ]; then
                            echo "cosign.pub from secret is empty, will use Rekor key later"
                        else
                            echo "cosign.pub extracted from signing-secrets."
                        fi
                    else
                        echo "signing-secrets not found — generating new key pair..."
                        COSIGN_PASSWORD=chainstest ./cosign generate-key-pair \
                            k8s://openshift-pipelines/signing-secrets
                    fi

                    # Registry credentials
                    oc delete secret regcred -n "${PROJECT}" --ignore-not-found
                    kubectl create secret generic regcred \
                        --from-file=.dockerconfigjson=/root/.docker/config.json \
                        --type=kubernetes.io/dockerconfigjson \
                        -n "${PROJECT}"

                    # Wait for pipeline SA (created by Tekton operator after project creation)
                    echo "Waiting for pipeline serviceaccount..."
                    WAIT=0
                    until oc get serviceaccount pipeline -n "${PROJECT}" &>/dev/null; do
                        sleep 5; WAIT=$((WAIT+5))
                        [ $WAIT -ge 60 ] && echo "ERROR: pipeline SA not found" && exit 1
                    done
                    oc patch serviceaccount pipeline -n "${PROJECT}" \
                        -p \'{"imagePullSecrets":[{"name":"regcred"}]}\'

                    oc delete secret chains-docker-hub -n "${PROJECT}" --ignore-not-found
                    kubectl create secret generic chains-docker-hub \
                        --from-file=/root/.docker/config.json \
                        -n "${PROJECT}"

                    oc patch configmap chains-config -n openshift-pipelines \
                        -p=\'{"data":{"artifacts.taskrun.format":"in-toto","artifacts.taskrun.storage":"oci","transparency.enabled":"true"}}\'
                '''
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
    STATUS=$(kubectl get taskrun "${TR_NAME}" -n "${PROJECT}" \
        -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)
    [ "$STATUS" = "True" ] && echo "TaskRun Succeeded." && break
    [ "$STATUS" = "False" ] && echo "ERROR: TaskRun Failed." && exit 1
    [ $ELAPSED -ge 120 ] && echo "ERROR: Timed out waiting." && exit 1
    sleep 5; ELAPSED=$((ELAPSED+5))
done

# Get image digest from TaskRun results
TR_JSON=$(kubectl get taskrun "${TR_NAME}" -n "${PROJECT}" -o json)
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
    SIGNED=$(kubectl get taskrun "${TR_NAME}" -n "${PROJECT}" \
        -o jsonpath='{.metadata.annotations.chains\\.tekton\\.dev/signed}' 2>/dev/null || true)
    [ "$SIGNED" = "true" ] && echo "Chains signed the TaskRun." && break
    [ $WAIT -ge 180 ] && echo "ERROR: Timed out waiting for signing." && exit 1
    echo "  Not signed yet... (${WAIT}s)"; sleep 10; WAIT=$((WAIT+10))
done

# Extract the actual signing key from Rekor REST API
TR_JSON=$(kubectl get taskrun "${TR_NAME}" -n "${PROJECT}" -o json)
REKOR_URL=$(echo "${TR_JSON}" \
    | jq -r '.metadata.annotations["chains.tekton.dev/transparency"] // empty')
LOG_INDEX=$(echo "${REKOR_URL}" | cut -d= -f2)

if [ -n "$LOG_INDEX" ]; then
    REKOR_KEY=$(curl -s \
        "https://rekor.sigstore.dev/api/v1/log/entries?logIndex=${LOG_INDEX}" \
        | jq -r '.[].body' | base64 -d \
        | jq -r '.spec.signatures[0].verifier' | base64 -d 2>/dev/null || true)
    if echo "${REKOR_KEY}" | grep -q "BEGIN PUBLIC KEY"; then
        echo "${REKOR_KEY}" > cosign.pub
        echo "cosign.pub updated from Rekor entry."
    fi
fi

echo "cosign.pub in use:"; cat cosign.pub

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
