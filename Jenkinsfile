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
                // verify_chains.sh is a real file in the repo (checked out by SCM).
                // No inline shell in Groovy strings = no escaping issues.
                sh "bash verify_chains.sh '${params.PROJECT}' '${params.IMAGE}' '${env.WORKDIR}'"
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
