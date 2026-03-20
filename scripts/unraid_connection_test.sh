#!/usr/bin/env bash
set -u

# Read-only connection/auth smoke test for the Unraid GraphQL API.
# Output is intentionally concise and excludes secrets.

BASE_URL="${UNRAID_BASE_URL:-}"
API_KEY="${UNRAID_API_KEY:-}"
TIMEOUT="${UNRAID_TIMEOUT_SECONDS:-10}"

if [[ -z "$BASE_URL" ]]; then
  echo "FAIL: Unraid base URL is not configured. Set UNRAID_BASE_URL and retry."
  exit 2
fi

if [[ -z "$API_KEY" ]]; then
  echo "FAIL: Unraid API key is not configured. Set UNRAID_API_KEY and retry."
  exit 2
fi

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "FAIL: UNRAID_TIMEOUT_SECONDS must be an integer."
  exit 2
fi

ENDPOINT="${BASE_URL%/}/graphql"
QUERY='{"query":"query HealthCheck { __typename info { os { release uptime } } }"}'

body_file="$(mktemp)"
err_file="$(mktemp)"
cleanup() {
  rm -f "$body_file" "$err_file"
}
trap cleanup EXIT

http_code="$(curl -sS \
  --connect-timeout "$TIMEOUT" \
  --max-time "$TIMEOUT" \
  -o "$body_file" \
  -w "%{http_code}" \
  -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_KEY}" \
  --data "$QUERY" 2>"$err_file")"
curl_status=$?

if [[ $curl_status -ne 0 ]]; then
  echo "FAIL: Network request failed for ${ENDPOINT}."
  echo "DETAIL: $(tr '\n' ' ' < "$err_file" | sed 's/[[:space:]]\+/ /g' | cut -c1-300)"
  exit 3
fi

if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
  echo "FAIL: Authentication to Unraid API failed. Verify UNRAID_API_KEY permissions/validity."
  exit 4
fi

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "FAIL: Unraid API returned HTTP ${http_code}."
  exit 5
fi

if command -v jq >/dev/null 2>&1; then
  has_errors="$(jq -r 'has("errors")' "$body_file" 2>/dev/null || echo "false")"
  if [[ "$has_errors" == "true" ]]; then
    first_error="$(jq -r '.errors[0].message // "Unknown GraphQL error"' "$body_file" 2>/dev/null)"
    echo "FAIL: GraphQL responded with errors."
    echo "DETAIL: ${first_error}"
    exit 6
  fi

  typename="$(jq -r '.data.__typename // "unknown"' "$body_file" 2>/dev/null)"
  release="$(jq -r '.data.info.os.release // "unknown"' "$body_file" 2>/dev/null)"
  uptime="$(jq -r '.data.info.os.uptime // "unknown"' "$body_file" 2>/dev/null)"

  echo "PASS: Unraid API reachable and authenticated."
  echo "ENDPOINT: ${ENDPOINT}"
  echo "GRAPHQL_TYPENAME: ${typename}"
  echo "OS_RELEASE: ${release}"
  echo "UPTIME: ${uptime}"
  exit 0
fi

if grep -q '"errors"' "$body_file"; then
  echo "FAIL: GraphQL responded with errors."
  exit 6
fi

echo "PASS: Unraid API reachable and authenticated."
echo "ENDPOINT: ${ENDPOINT}"
echo "NOTE: Install jq for richer diagnostics."
exit 0
