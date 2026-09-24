#!/bin/bash
# =============================================================================
# Aliyun API authentication script for RESTie
#
# Input environment variables (set by RESTie):
#   RESTIE_METHOD  — HTTP method (GET, POST, etc.)
#   RESTIE_PATH    — API path
#   RESTIE_QUERY   — query string
#   RESTIE_BODY    — request body JSON
#
# Additional env vars (configured in the preset's auth.env):
#   ALIYUN_ACCESS_KEY_ID      — Your Aliyun access key ID
#   ALIYUN_ACCESS_KEY_SECRET  — Your Aliyun access key secret
#
# Aliyun uses HMAC-SHA1 signature with specific parameter ordering.
# Reference: https://www.alibabacloud.com/help/en/sdk/product-overview/api-call-method
#
# Output: HTTP headers, one per line in "Header: value" format
# =============================================================================

set -euo pipefail

# --- Read inputs ---
METHOD="${RESTIE_METHOD:-GET}"
ACCESS_KEY_ID="${ALIYUN_ACCESS_KEY_ID:?ALIYUN_ACCESS_KEY_ID not set}"
ACCESS_KEY_SECRET="${ALIYUN_ACCESS_KEY_SECRET:?ALIYUN_ACCESS_KEY_SECRET not set}"

# Aliyun RPC APIs use query params: Signature, Timestamp, etc.
# The signature is calculated over sorted query params.

# --- Build timestamp ---
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NONCE=$(date +%s%N | md5sum | head -c 32)

# --- Build canonical query string ---
# Aliyun requires: SignatureNonce, Timestamp, Format, Version, AccessKeyId, SignatureMethod, SignatureVersion
# Plus any API-specific params

# For RPC-style APIs, the signature string is:
#   HTTP_METHOD + "&" + percent_encode("/") + "&" + percent_encode(canonical_query)
# where canonical_query is sorted by key

# The Version below is product specific — change it to match the API you call.
QUERY_PARAMS="Format=JSON&Version=2014-05-26&AccessKeyId=${ACCESS_KEY_ID}&SignatureMethod=HMAC-SHA1&Timestamp=${TIMESTAMP}&SignatureVersion=1.0&SignatureNonce=${NONCE}"

# Add any extra query from RESTIE
if [[ -n "${RESTIE_QUERY:-}" ]]; then
    QUERY_PARAMS="${QUERY_PARAMS}&${RESTIE_QUERY}"
fi

# Sort params by key
SORTED_QUERY=$(echo "$QUERY_PARAMS" | tr '&' '\n' | sort | tr '\n' '&' | sed 's/&$//')

# --- Percent encode ---
percent_encode() {
    echo -n "$1" | jq -sRr @uri 2>/dev/null || \
    echo -n "$1" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe='-_.~'))"
}

# --- Build string to sign ---
STRING_TO_SIGN="${METHOD}&$(percent_encode "/")&$(percent_encode "$SORTED_QUERY")"

# --- Calculate signature ---
SIGNATURE=$(echo -n "$STRING_TO_SIGN" | openssl dgst -sha1 -mac HMAC -macopt "key:${ACCESS_KEY_SECRET}&" -base64 -binary | base64)

# --- Output ---
# The signature belongs in the query string of the request you send. RESTie
# forwards these as headers so a proxy or wrapper can pick them up; when calling
# Aliyun directly, append Signature=... and the other params to RESTIE_QUERY.
echo "X-Aliyun-Signature: ${SIGNATURE}"
echo "X-Aliyun-Timestamp: ${TIMESTAMP}"
echo "X-Aliyun-Nonce: ${NONCE}"
echo "X-Aliyun-AccessKeyId: ${ACCESS_KEY_ID}"
