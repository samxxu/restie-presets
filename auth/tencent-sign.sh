#!/bin/bash
# =============================================================================
# Tencent Cloud API authentication script for RESTie
#
# Implements TC3-HMAC-SHA256 signature algorithm.
# Reference: https://cloud.tencent.com/document/api/213/30654
#
# Input environment variables (set by RESTie):
#   RESTIE_METHOD  — HTTP method (GET, POST, etc.)
#   RESTIE_PATH    — API path (e.g. /)
#   RESTIE_QUERY   — query string
#   RESTIE_BODY    — request body JSON
#
# Additional env vars (configured in the preset's auth.env):
#   TENCENTCLOUD_SECRET_ID    — Your Tencent Cloud SecretId
#   TENCENTCLOUD_SECRET_KEY   — Your Tencent Cloud SecretKey
#   TENCENTCLOUD_SERVICE      — Service name (e.g. cvm, cdn). Default: cvm
#   TENCENTCLOUD_REGION       — Region (e.g. ap-beijing). Default: ap-beijing
#
# Output: HTTP headers, one per line in "Header: value" format
# =============================================================================

set -euo pipefail

# --- Read inputs ---
METHOD="${RESTIE_METHOD:-POST}"
PATH_VAL="${RESTIE_PATH:-/}"
QUERY_VAL="${RESTIE_QUERY:-}"
BODY_VAL="${RESTIE_BODY:-}"

SECRET_ID="${TENCENTCLOUD_SECRET_ID:?TENCENTCLOUD_SECRET_ID not set}"
SECRET_KEY="${TENCENTCLOUD_SECRET_KEY:?TENCENTCLOUD_SECRET_KEY not set}"
SERVICE="${TENCENTCLOUD_SERVICE:-cvm}"
REGION="${TENCENTCLOUD_REGION:-ap-beijing}"

# --- Timestamp ---
TIMESTAMP=$(date +%s)
DATE=$(date -u -r "$TIMESTAMP" +"%Y-%m-%d")

# --- Canonical query string ---
# Sort query params by key
canonical_query() {
    if [[ -z "$1" ]]; then
        echo ""
        return
    fi
    echo "$1" | tr '&' '\n' | sort | tr '\n' '&' | sed 's/&$//'
}
CANONICAL_QUERY=$(canonical_query "$QUERY_VAL")

# --- Canonical headers ---
# Required: host, content-type (lowercase, sorted by key)
HOST="tencentcloudapi.com"
CONTENT_TYPE="application/json; charset=utf-8"
CANONICAL_HEADERS="content-type:${CONTENT_TYPE}
host:${SERVICE}.${HOST}
"
SIGNED_HEADERS="content-type;host"

# --- Hashed payload ---
if command -v sha256sum >/dev/null 2>&1; then
    HASHED_PAYLOAD=$(echo -n "$BODY_VAL" | sha256sum | cut -d' ' -f1)
else
    HASHED_PAYLOAD=$(echo -n "$BODY_VAL" | openssl dgst -sha256 -hex | sed 's/^.* //')
fi

# --- Canonical request ---
CANONICAL_REQUEST="${METHOD}
${PATH_VAL}
${CANONICAL_QUERY}
${CANONICAL_HEADERS}
${SIGNED_HEADERS}
${HASHED_PAYLOAD}"

# --- String to sign ---
if command -v sha256sum >/dev/null 2>&1; then
    HASHED_CANONICAL=$(echo -n "$CANONICAL_REQUEST" | sha256sum | cut -d' ' -f1)
else
    HASHED_CANONICAL=$(echo -n "$CANONICAL_REQUEST" | openssl dgst -sha256 -hex | sed 's/^.* //')
fi

ALGORITHM="TC3-HMAC-SHA256"
CREDENTIAL_SCOPE="${DATE}/${SERVICE}/tc3_request"
STRING_TO_SIGN="${ALGORITHM}
${TIMESTAMP}
${CREDENTIAL_SCOPE}
${HASHED_CANONICAL}"

# --- HMAC-SHA256 helpers ---
hmac_sha256_hex() {
    # $1 = key, $2 = message
    echo -n "$2" | openssl dgst -sha256 -mac HMAC -macopt "key:$1" | sed 's/^.* //'
}

hmac_sha256_bin() {
    # $1 = key (binary string), $2 = message
    echo -n "$2" | openssl dgst -sha256 -mac HMAC -macopt "key:$1" -binary | xxd -p | tr -d '\n'
}

# --- Derive signing key ---
# TC3 uses: SecretDate = HMAC_SHA256("TC3" + SecretKey, Date)
#          SecretService = HMAC_SHA256(SecretDate, Service)
#          SecretSigning = HMAC_SHA256(SecretService, "tc3_request")
SECRET_DATE=$(hmac_sha256_bin "TC3${SECRET_KEY}" "$DATE")
SECRET_SERVICE=$(hmac_sha256_hex "$SECRET_DATE" "$SERVICE")
SECRET_SIGNING=$(hmac_sha256_hex "$SECRET_SERVICE" "tc3_request")

# --- Signature ---
SIGNATURE=$(hmac_sha256_hex "$SECRET_SIGNING" "$STRING_TO_SIGN")

# --- Authorization header ---
AUTHORIZATION="${ALGORITHM} Credential=${SECRET_ID}/${CREDENTIAL_SCOPE}, SignedHeaders=${SIGNED_HEADERS}, Signature=${SIGNATURE}"

# --- Output headers ---
# X-TC-Action / X-TC-Version identify the operation; override them via the query
# string or by editing this script for the product you are calling.
echo "Authorization: ${AUTHORIZATION}"
echo "Host: ${SERVICE}.tencentcloudapi.com"
echo "X-TC-Action: ${TENCENTCLOUD_ACTION:-DescribeInstances}"
echo "X-TC-Version: ${TENCENTCLOUD_VERSION:-2017-03-12}"
echo "X-TC-Timestamp: ${TIMESTAMP}"
echo "X-TC-Region: ${REGION}"
echo "Content-Type: ${CONTENT_TYPE}"
