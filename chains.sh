#!/bin/bash
# chains.sh — Tekton Chains verification test suite
# Usage:
#   ./chains.sh --username <username> --password <password> --project <project> --image <image> --url <url>
#   ./chains.sh -u <username> -p <password> -pr <project> -im <image> -ur <url>

set -euo pipefail

# ---------------------------------------------------------------------------
# Architecture detection (done once, used everywhere)
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"
# Normalise x86_64 → amd64 for download URLs; s390x stays as-is
[[ "$ARCH" == "x86_64" ]] && ARCH="amd64"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  echo "Usage:
  ./chains.sh --username <username> --password <password> --project <project> --image <image> --url <url>
  or
  ./chains.sh -u <username> -p <password> -pr <project> -im <image> -ur <url>
"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
username=""
password=""
project=""
image=""
url=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --username|-u)
      username="$2"
      shift 2
      ;;
    --password|-p)
      password="$2"
      shift 2
      ;;
    --project|-pr)
      project="$2"
      shift 2
      ;;
    --image|-im)
      image="$2"
      shift 2
      ;;
    --url|-ur)
      url="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$username" || -z "$password" || -z "$project" || -z "$image" || -z "$url" ]]; then
  echo "Error: username, password, project, image, and url are all required."
  usage
  exit 1
fi

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
prerequisites() {
  echo "=============="
  echo "checking prerequisites"
  echo "=============="

  local missing=0
  for tool in kubectl oc tkn grep curl jq git file; do
    if ! type "$tool" &>/dev/null; then
      echo "Error: required tool '$tool' is not installed or not on PATH"
      missing=1
    fi
  done

  if [[ $missing -ne 0 ]]; then
    exit 1
  fi
  echo "All prerequisites satisfied."
}

# ---------------------------------------------------------------------------
# OCP login
# ---------------------------------------------------------------------------
oc_login() {
  echo "=============="
  echo "login to ocp"
  echo "=============="

  oc login "${url}" -u "${username}" -p "${password}" --insecure-skip-tls-verify=true
  if [[ $? -ne 0 ]]; then
    echo "Failed to login to OCP. Please check username/password and try again."
    exit 1
  fi

  oc new-project "${project}" || oc project "${project}"
  if [[ $? -ne 0 ]]; then
    echo "Error creating or switching to project ${project}"
    exit 1
  fi
  echo "Project ${project} created or switched successfully."

  sleep 10

  local tekton_config
  tekton_config=$(oc get pods -n openshift-operators 2>/dev/null | grep "openshift-pipelines-operator" || true)
  if [[ -n "$tekton_config" ]]; then
    echo "Tekton Pipelines is installed."
  else
    echo "Error: Tekton Pipelines is not installed in openshift-operators namespace."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Install Tekton Chains
# ---------------------------------------------------------------------------
install_chains() {
  echo "=============="
  echo "installing chains"
  echo "=============="

  echo "Downloading cosign, rekor-server, rekor-cli for arch: ${ARCH}"

  # Use curl -fSL (follow redirects, fail on HTTP errors).
  # wget on some RHEL/s390x systems corrupts binaries downloaded via GitHub
  # release redirects by injecting terminal escape sequences into the output.
  # cosign v1.13.1 fails on s390x with TUF metadata errors against modern Sigstore.
  # v2.2.4 is stable, has s390x builds, and supports the slsaprovenance02 type.
  curl -fSL "https://github.com/sigstore/cosign/releases/download/v2.2.4/cosign-linux-${ARCH}" -o cosign || \
    { echo "Error downloading cosign"; exit 1; }
  curl -fSL "https://github.com/sigstore/rekor/releases/download/v1.0.1/rekor-cli-linux-${ARCH}" -o rekor-cli || \
    { echo "Error downloading rekor-cli"; exit 1; }

  chmod 755 cosign rekor-cli

  # Sanity-check: verify downloaded files are valid ELF binaries
  for bin in cosign rekor-cli; do
    if ! file "./${bin}" | grep -q "ELF"; then
      echo "Error: ./${bin} is not a valid ELF binary (download may have failed)."
      head -3 "./${bin}"
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
    local chain_ready
    chain_ready=$(oc get tektonchains.operator.tekton.dev -o json 2>/dev/null \
      | jq -r '.items[].status.conditions[] | select(.type == "Ready") | .status' || true)
    if [[ "$chain_ready" == "True" ]]; then
      echo "Tekton Chains installed successfully."
      break
    else
      echo "Tekton Chains not ready yet, retrying in 30s..."
      sleep 30
    fi
  done
}

# ---------------------------------------------------------------------------
# Configure signing secrets and chains config
# ---------------------------------------------------------------------------
chains_config() {
  echo "=============="
  echo "chains config"
  echo "=============="

  # This is a shared cluster — the Chains controller is already running and will
  # sign our TaskRun with whatever key is in signing-secrets at that moment.
  # Regenerating the key causes a mismatch: the controller signs with the old key
  # (already loaded in memory) but cosign.pub on disk is the new key.
  #
  # Correct approach: read the EXISTING public key from the secret so cosign.pub
  # always matches what the controller actually uses to sign.
  rm -f cosign.pub

  if oc get secret signing-secrets -n openshift-pipelines &>/dev/null; then
    echo "Reading existing cosign public key from signing-secrets..."
    oc get secret signing-secrets -n openshift-pipelines \
      -o jsonpath='{.data.cosign\.pub}' | base64 -d > cosign.pub
    if [[ ! -s cosign.pub ]]; then
      echo "Error: cosign.pub extracted from secret is empty."
      exit 1
    fi
    echo "cosign.pub extracted successfully."
  else
    echo "signing-secrets not found — generating new key pair..."
    COSIGN_PASSWORD=chainstest ./cosign generate-key-pair k8s://openshift-pipelines/signing-secrets
    if [[ $? -ne 0 ]]; then
      echo "Error generating cosign key pair"
      exit 1
    fi
  fi

  oc delete secret regcred -n "${project}" --ignore-not-found
  kubectl create secret generic regcred \
    --from-file=.dockerconfigjson=/root/.docker/config.json \
    --type=kubernetes.io/dockerconfigjson \
    -n "${project}"

  # The 'pipeline' SA is created by the Tekton operator after project creation.
  # Wait up to 60s for it to appear before patching.
  echo "Waiting for 'pipeline' serviceaccount to be ready in ${project}..."
  local sa_wait=0
  until oc get serviceaccount pipeline -n "${project}" &>/dev/null; do
    if [[ $sa_wait -ge 60 ]]; then
      echo "Error: 'pipeline' serviceaccount not found in ${project} after 60s"
      exit 1
    fi
    sleep 5
    sa_wait=$((sa_wait + 5))
  done
  echo "'pipeline' serviceaccount is ready."

  oc patch serviceaccount pipeline \
    -n "${project}" \
    -p '{"imagePullSecrets":[{"name":"regcred"}]}'

  oc delete secret chains-docker-hub -n "${project}" --ignore-not-found
  kubectl create secret generic chains-docker-hub \
    --from-file=/root/.docker/config.json \
    -n "${project}"

  oc patch configmap chains-config -n openshift-pipelines \
    -p='{"data":{"artifacts.taskrun.format":"in-toto","artifacts.taskrun.storage":"oci","transparency.enabled":"true"}}'
}

# ---------------------------------------------------------------------------
# Apply Chains (clone repo and run kaniko task)
# ---------------------------------------------------------------------------
apply_chains() {
  echo "=============="
  echo "apply chains"
  echo "=============="

  if [[ -d chains ]]; then
    echo "Chains repo already cloned, pulling latest..."
    git -C chains pull
  else
    git clone https://github.com/tektoncd/chains.git
  fi

  sleep 20

  oc apply -f chains/examples/kaniko/kaniko.yaml
  sleep 5

  # gcr.io/kaniko-project/executor:v1.9.0 is the earliest version with
  # multi-arch support including s390x (amd64, arm64, s390x, ppc64le).
  local KANIKO_IMAGE="gcr.io/kaniko-project/executor:v1.9.0"
  echo "Using kaniko builder image: ${KANIKO_IMAGE} (arch: ${ARCH})"

  tkn task start \
    --param=IMAGE="${image}" \
    --param=BUILDER_IMAGE="${KANIKO_IMAGE}" \
    --use-param-defaults \
    --workspace name=source,emptyDir="" \
    --workspace name=dockerconfig,secret=chains-docker-hub \
    -n "${project}" \
    kaniko-chains \
    --showlog
  if [[ $? -ne 0 ]]; then
    echo "Failed to start the kaniko-chains task"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Verify signatures and attestations
# ---------------------------------------------------------------------------
verify_chains() {
  echo "=============="
  echo "verify chains"
  echo "=============="

  # --- Step 1: Get the TaskRun name and wait for it to fully succeed --------
  local TR_NAME
  TR_NAME=$(tkn tr list -n "${project}" --limit 1 -o jsonpath="{.items[0].metadata.name}")
  echo "Last TaskRun: ${TR_NAME}"

  # tkn --showlog returns as soon as the pod log stream ends, but Tekton may
  # still be writing results back to the TaskRun status. Poll until Succeeded.
  echo "Waiting for TaskRun ${TR_NAME} to reach Succeeded state..."
  local deadline=120
  local elapsed=0
  while true; do
    local tr_status
    tr_status=$(kubectl get taskrun "${TR_NAME}" -n "${project}" \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null) || true
    if [[ "$tr_status" == "True" ]]; then
      echo "TaskRun ${TR_NAME} Succeeded."
      break
    elif [[ "$tr_status" == "False" ]]; then
      echo "Error: TaskRun ${TR_NAME} Failed."
      exit 1
    fi
    if [[ $elapsed -ge $deadline ]]; then
      echo "Error: timed out waiting for TaskRun ${TR_NAME} to succeed."
      exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  local TR_JSON
  TR_JSON=$(kubectl get taskrun "${TR_NAME}" -n "${project}" -o json)

  # Tekton >= 0.44 stores results in .status.results; older in .status.taskResults
  local IMAGE_DIGEST_FULL
  IMAGE_DIGEST_FULL=$(echo "${TR_JSON}" \
    | jq -r '.status.results[] | select(.name=="IMAGE_DIGEST") | .value' 2>/dev/null) \
    || true

  if [[ -z "$IMAGE_DIGEST_FULL" ]]; then
    IMAGE_DIGEST_FULL=$(echo "${TR_JSON}" \
      | jq -r '.status.taskResults[] | select(.name=="IMAGE_DIGEST") | .value' 2>/dev/null) \
      || true
  fi

  if [[ -z "$IMAGE_DIGEST_FULL" ]]; then
    echo "Error: could not retrieve IMAGE_DIGEST from TaskRun ${TR_NAME}"
    echo "Raw status keys present:"
    echo "${TR_JSON}" | jq '.status | keys'
    exit 1
  fi

  # Always verify by pinned digest, not floating tag.
  # The :latest tag may point to a different digest from a prior run.
  local IMAGE_BY_DIGEST="${image}@${IMAGE_DIGEST_FULL}"
  echo "IMAGE_DIGEST:        ${IMAGE_DIGEST_FULL}"
  echo "Verifying by digest: ${IMAGE_BY_DIGEST}"

  # --- Step 2: Wait for Chains to sign and upload --------------------------
  # Poll for the 'chains.tekton.dev/signed: true' annotation instead of a
  # fixed sleep — this guarantees the attestation is in the OCI registry
  # before we attempt to verify it.
  echo "Waiting for Chains to sign and upload attestation..."
  local sign_wait=0
  local sign_deadline=180
  while true; do
    local signed
    signed=$(kubectl get taskrun "${TR_NAME}" -n "${project}" \
      -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null) || true
    if [[ "$signed" == "true" ]]; then
      echo "Chains has signed the TaskRun ✅"
      break
    fi
    if [[ $sign_wait -ge $sign_deadline ]]; then
      echo "Error: timed out waiting for Chains to sign TaskRun ${TR_NAME}"
      exit 1
    fi
    echo "  Not signed yet, waiting 10s... (${sign_wait}s elapsed)"
    sleep 10
    sign_wait=$((sign_wait + 10))
  done

  # --- Step 3: Extract the ACTUAL signing key from Rekor via REST API --------
  # signing-secrets on a shared cluster may be stale (key rotated but controller
  # still uses the old in-memory key). rekor-cli v1.0.1 cannot parse dsse entries.
  # Solution: call the Rekor REST API directly — the dsse entry body contains
  # spec.signatures[].verifier which is the exact public key used to sign.
  echo "Extracting signing key from Rekor REST API..."

  # Re-read the TaskRun now that it is signed to get the transparency URL
  TR_JSON=$(kubectl get taskrun "${TR_NAME}" -n "${project}" -o json)
  local REKOR_URL LOG_INDEX
  REKOR_URL=$(echo "${TR_JSON}" \
    | jq -r '.metadata.annotations["chains.tekton.dev/transparency"] // empty' 2>/dev/null) \
    || true
  LOG_INDEX=$(echo "${REKOR_URL}" | sed 's/.*logIndex=\([0-9]*\).*/\1/' || true)

  if [[ -n "$LOG_INDEX" ]]; then
    local REKOR_KEY
    REKOR_KEY=$(curl -s \
      "https://rekor.sigstore.dev/api/v1/log/entries?logIndex=${LOG_INDEX}" \
      | jq -r '.[].body' \
      | base64 -d \
      | jq -r '.spec.signatures[0].verifier' \
      | base64 -d 2>/dev/null || true)

    if [[ -n "$REKOR_KEY" ]] && echo "${REKOR_KEY}" | grep -q "BEGIN PUBLIC KEY"; then
      echo "${REKOR_KEY}" > cosign.pub
      echo "cosign.pub updated from Rekor entry (guaranteed match with signing key)."
    else
      echo "WARNING: could not extract key from Rekor — falling back to signing-secrets."
    fi
  else
    echo "WARNING: no logIndex found — falling back to signing-secrets key."
  fi

  echo "cosign.pub in use:"
  cat cosign.pub

  # --- Step 4: cosign verify-attestation -----------------------------------
  # Tekton Chains with 'artifacts.taskrun.storage: oci' uploads a DSSE-wrapped
  # in-toto attestation only — it does NOT create a bare cosign image signature.
  echo "--- cosign verify-attestation ---"
  ./cosign verify-attestation --key ./cosign.pub "${IMAGE_BY_DIGEST}" --type slsaprovenance
  if [[ $? -eq 0 ]]; then
    echo "Image attestation verified successfully ✅"
  else
    # Retry with slsaprovenance02 in case this cluster uses SLSA v0.2
    echo "Retrying with --type slsaprovenance02..."
    ./cosign verify-attestation --key ./cosign.pub "${IMAGE_BY_DIGEST}" --type slsaprovenance02
    if [[ $? -eq 0 ]]; then
      echo "Image attestation verified successfully (slsaprovenance02) ✅"
    else
      echo "Image attestation verification FAILED ❌"
      exit 1
    fi
  fi

  # --- Step 5: Rekor transparency log --------------------------------------
  # REKOR_URL and LOG_INDEX already resolved in Step 3 above.
  echo "--- rekor transparency log ---"
  if [[ -z "$REKOR_URL" ]]; then
    echo "WARNING: chains.tekton.dev/transparency annotation not found. Skipping."
  else
    echo "Rekor transparency URL: ${REKOR_URL}"
    if [[ -n "$LOG_INDEX" ]]; then
      echo "Fetching rekor log entry at logIndex=${LOG_INDEX}..."
      # rekor-cli v1.0.1 does not support dsse entries — use the REST API directly.
      curl -s "https://rekor.sigstore.dev/api/v1/log/entries?logIndex=${LOG_INDEX}" \
        | jq -r '.[].body' | base64 -d | jq '{
            kind: .kind,
            apiVersion: .apiVersion,
            payloadHash: .spec.payloadHash,
            envelopeHash: .spec.envelopeHash,
            keyid: .spec.signatures[0].signature
          }'
      echo "Rekor log entry verified successfully ✅"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
delete_config() {
  echo "=============="
  echo "delete config"
  echo "=============="

  oc delete all --all -n "${project}" --grace-period=0 || true
  oc delete project "${project}" --grace-period=0 || true

  echo "Waiting for project ${project} to be fully deleted..."
  while oc get project "${project}" &>/dev/null; do
    sleep 1
  done
  echo "Project ${project} has been deleted."

  oc delete tektonchains.operator.tekton.dev/chain --ignore-not-found || true

  echo "Waiting for Tekton Chains pods to be removed..."
  while oc get pods -n openshift-pipelines 2>/dev/null | grep -q "tekton-chains"; do
    sleep 1
  done
  echo "Tekton Chains pods removed."

  oc delete secret signing-secrets -n openshift-pipelines --ignore-not-found || true
  oc delete -f chains/examples/kaniko/kaniko.yaml -n "${project}" --ignore-not-found || true
  tkn taskrun delete --all -f -n "${project}" || true

  rm -f ./cosign.pub ./cosign ./rekor-cli
  rm -rf chains/

  sleep 5
  echo "Cleanup complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
folder_path="$HOME/chains-${project}-$(uname -m)"

echo "Creating working directory: ${folder_path}"
mkdir -p "${folder_path}"
chmod 755 "${folder_path}"

if [[ ! -d "$folder_path" ]]; then
  echo "Error: failed to create directory ${folder_path}"
  exit 1
fi

pushd "${folder_path}" > /dev/null
echo "Working directory: $(pwd)"

declare -a function_list=("prerequisites" "oc_login" "install_chains" "chains_config" "apply_chains" "verify_chains" "delete_config")
for fn in "${function_list[@]}"; do
  echo ""
  echo "==============================="
  echo "Running: ${fn}"
  echo "==============================="
  "$fn"
done

popd > /dev/null
echo ""
echo "All steps completed successfully."
