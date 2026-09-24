#!/bin/bash
# =============================================================================
# AWS SigV4 authentication script for RESTie
#
# Input environment variables (set by RESTie):
#   RESTIE_METHOD  — HTTP method (GET, POST, etc.)
#   RESTIE_PATH    — API path (e.g. /?Action=DescribeInstances)
#   RESTIE_QUERY   — query string
#   RESTIE_BODY    — request body JSON
#
# Additional env vars (configured in the preset's auth.env):
#   AWS_ACCESS_KEY_ID     — Your AWS access key
#   AWS_SECRET_ACCESS_KEY — Your AWS secret key
#   AWS_REGION            — AWS region (e.g. us-east-1)
#   AWS_SERVICE           — AWS service (e.g. ec2, s3, iam)
#
# Output: HTTP headers, one per line in "Header: value" format
# =============================================================================

set -euo pipefail

# --- Read inputs ---
METHOD="${RESTIE_METHOD:-GET}"
PATH_QUERY="${RESTIE_PATH:-/}"
REGION="${AWS_REGION:-us-east-1}"
SERVICE="${AWS_SERVICE:-ec2}"
ACCESS_KEY="${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID not set}"
SECRET_KEY="${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY not set}"

# --- Split path and query ---
# AWS APIs often use query params (e.g. ?Action=...) rather than path segments
QUERY="${RESTIE_QUERY:-}"

# --- Timestamp ---
# Must be computed before the canonical headers, which embed it.
AMZ_DATE=$(date -u +"%Y%m%dT%H%M%SZ")
DATE_STAMP=$(date -u +"%Y%m%d")

# --- Build canonical request ---
# For AWS, the path is usually "/" and params are in query
CANONICAL_PATH="/"
if [[ "$PATH_QUERY" == *"?"* ]]; then
    CANONICAL_PATH="${PATH_QUERY%%\?*}"
    QUERY="${PATH_QUERY#*\?}"
fi

# Sort query parameters
if [[ -n "$QUERY" ]]; then
    CANONICAL_QUERY=$(echo "$QUERY" | tr '&' '\n' | sort | tr '\n' '&' | sed 's/&$//')
else
    CANONICAL_QUERY=""
fi

# Canonical headers (minimal)
HOST="ec2.${AWS_REGION:-us-east-1}.amazonaws.com"
if [[ "$SERVICE" == "s3" ]]; then
    HOST="${AWS_BUCKET:-bucket}.s3.${AWS_REGION:-us-east-1}.amazonaws.com"
fi

CANONICAL_HEADERS="host:${HOST}
x-amz-date:${AMZ_DATE}
"
SIGNED_HEADERS="host;x-amz-date"

# Payload hash
PAYLOAD_HASH="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"  # empty body
if [[ -n "${RESTIE_BODY:-}" ]]; then
    PAYLOAD_HASH=$(echo -n "$RESTIE_BODY" | openssl dgst -sha256 -hex | awk '{print $NF}')
fi

# --- Build string to sign ---
CREDENTIAL="${ACCESS_KEY}/${DATE_STAMP}/${REGION}/${SERVICE}/aws4_request"

STRING_TO_SIGN="AWS4-HMAC-SHA256
${AMZ_DATE}
${REGION}/${SERVICE}/aws4_request
$(printf '%s\n%s\n%s\n%s\n%s' \
    "$CANONICAL_PATH" \
    "$CANONICAL_QUERY" \
    "$CANONICAL_HEADERS" \
    "$SIGNED_HEADERS" \
    "$PAYLOAD_HASH" | openssl dgst -sha256 -hex | awk '{print $NF}')"

# --- Calculate signature ---
derive_key() {
    local k_date=$(echo -n "$DATE_STAMP" | openssl dgst -sha256 -mac HMAC -macopt "key:AWS4$SECRET_KEY" -hex | awk '{print $NF}')
    local k_region=$(echo -n "$REGION" | openssl dgst -sha256 -mac HMAC -macopt "key:$k_date" -hex | awk '{print $NF}')
    local k_service=$(echo -n "$SERVICE" | openssl dgst -sha256 -mac HMAC -macopt "key:$k_region" -hex | awk '{print $NF}')
    local k_signing=$(echo -n "aws4_request" | openssl dgst -sha256 -mac HMAC -macopt "key:$k_service" -hex | awk '{print $NF}')
    echo "$k_signing"
}

SIGNATURE=$(echo -n "$STRING_TO_SIGN" | openssl dgst -sha256 -mac HMAC -macopt "key:$(derive_key)" -hex | awk '{print $NF}')

# --- Output headers ---
AUTH_HEADER="AWS4-HMAC-SHA256 Credential=${CREDENTIAL}, SignedHeaders=${SIGNED_HEADERS}, Signature=${SIGNATURE}"
echo "Authorization: ${AUTH_HEADER}"
echo "X-Amz-Date: ${AMZ_DATE}"
echo "X-Amz-Content-Sha256: ${PAYLOAD_HASH}"
echo "Host: ${HOST}"
