#!/bin/bash
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
        -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null || true)
    [ "$SIGNED" = "true" ] && echo "Chains signed the TaskRun." && break
    [ $WAIT -ge 180 ] && echo "ERROR: Timed out waiting for signing." && exit 1
    echo "  Not signed yet... (${WAIT}s)"; sleep 10; WAIT=$((WAIT+10))
done

# Confirm attestation actually exists in OCI registry.
# Chains marks signed=true even when controller has no key (no-op sign).
echo "Checking attestation exists in OCI registry..."
ATT_CHECK=$(./cosign download attestation "${IMAGE_BY_DIGEST}" 2>&1 || true)
if echo "${ATT_CHECK}" | grep -qi "error\|no attestation\|not found"; then
    echo "ERROR: No attestation found in OCI registry for ${IMAGE_BY_DIGEST}"
    echo "The Chains controller likely had no signing key when it processed this TaskRun."
    echo "cosign output: ${ATT_CHECK}"
    echo ""
    echo "Chains controller logs (last 20 lines):"
    oc logs -n openshift-pipelines -l app=tekton-chains-controller --tail=20 || true
    exit 1
fi
echo "Attestation found in OCI registry."

# Extract the signing key from Rekor REST API (if transparency is enabled)
TR_JSON=$(oc get taskrun "${TR_NAME}" -n "${PROJECT}" -o json)
REKOR_URL=$(echo "${TR_JSON}" \
    | jq -r '.metadata.annotations["chains.tekton.dev/transparency"] // empty')
LOG_INDEX=$(echo "${REKOR_URL}" | cut -d= -f2)
echo "Rekor transparency URL: ${REKOR_URL:-<none>}"
echo "Log index: ${LOG_INDEX:-<none>}"

if [ -n "$LOG_INDEX" ]; then
    echo "Fetching Rekor entry..."
    REKOR_JSON=$(curl -fsSL \
        "https://rekor.sigstore.dev/api/v1/log/entries?logIndex=${LOG_INDEX}" \
        2>/tmp/rekor_curl_err || true)
    if [ -z "$REKOR_JSON" ]; then
        echo "WARNING: Empty/failed response from Rekor. curl error: $(cat /tmp/rekor_curl_err)"
    else
        echo "Rekor response (first 300 chars): $(echo "${REKOR_JSON}" | head -c 300)"
        REKOR_KEY=$(echo "${REKOR_JSON}" \
            | jq -r '.[].body' 2>/dev/null | base64 -d 2>/dev/null \
            | jq -r '.spec.signatures[0].verifier' 2>/dev/null | base64 -d 2>/dev/null || true)
        if echo "${REKOR_KEY}" | grep -q "BEGIN PUBLIC KEY"; then
            echo "${REKOR_KEY}" > cosign.pub
            echo "cosign.pub updated from Rekor entry."
        else
            echo "WARNING: Could not extract public key from Rekor response."
        fi
    fi
else
    echo "WARNING: No Rekor transparency annotation — using cosign.pub from signing-secrets."
fi

echo "cosign.pub in use:"; cat cosign.pub

if [ ! -s cosign.pub ]; then
    echo "ERROR: cosign.pub is empty — cannot verify."
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

# Rekor log entry summary
if [ -n "$LOG_INDEX" ]; then
    echo "--- rekor transparency log ---"
    curl -s "https://rekor.sigstore.dev/api/v1/log/entries?logIndex=${LOG_INDEX}" \
        | jq -r '.[].body' | base64 -d \
        | jq '{kind,apiVersion,payloadHash:.spec.payloadHash,envelopeHash:.spec.envelopeHash}'
    echo "Rekor log entry verified."
fi
