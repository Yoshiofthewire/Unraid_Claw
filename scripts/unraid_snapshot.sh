#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/unraid_common.sh"

require_base_url
require_api_key
require_timeout
require_command "curl" "required for Unraid API calls"
require_command "jq" "required to normalize snapshot output"
ensure_state_dirs

QUERY='{"query":"query UnraidMonitorSnapshot { info { os { platform distro release uptime } cpu { model cores usage temperature } memory { total used free usage } } array { state syncAction syncProgress errors disks { name status size used temperature smartStatus } parity { status lastCheck errors } } docker { enabled containers { id name image state status uptime ports } } }"}'

body_file="$(mktemp)"
err_file="$(mktemp)"
snapshot_tmp="$(mktemp)"
cleanup() {
  rm -f "$body_file" "$err_file" "$snapshot_tmp"
}
trap cleanup EXIT

http_code="$(graphql_post "$QUERY" "$body_file" "$err_file")"
curl_status=$?

if [[ $curl_status -ne 0 ]]; then
  echo "FAIL: Network request failed for $(endpoint)."
  echo "DETAIL: $(sanitize_error_file "$err_file")"
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

if ! jq -e '.data != null' "$body_file" >/dev/null 2>&1; then
  echo "FAIL: GraphQL response did not contain data."
  exit 6
fi

timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

jq \
  --arg ts "$timestamp" \
  --arg endpoint "$(endpoint)" '
  {
    timestamp: $ts,
    endpoint: $endpoint,
    warnings: (if has("errors") then ["Some API fields were unavailable for this Unraid version; output is partial."] else [] end),
    graphql_errors: (.errors // []),
    data: (.data // {})
  }
' "$body_file" > "$snapshot_tmp"

latest_path="$(latest_snapshot_path)"
archived_path="$(timestamped_snapshot_path)"
cp "$snapshot_tmp" "$latest_path"
cp "$snapshot_tmp" "$archived_path"

if jq -e '.graphql_errors | length > 0' "$latest_path" >/dev/null 2>&1; then
  echo "PASS: Snapshot captured with partial-data warning."
  echo "LATEST_SNAPSHOT: ${latest_path}"
  echo "ARCHIVE_SNAPSHOT: ${archived_path}"
  exit 0
fi

echo "PASS: Snapshot captured successfully."
echo "LATEST_SNAPSHOT: ${latest_path}"
echo "ARCHIVE_SNAPSHOT: ${archived_path}"
exit 0