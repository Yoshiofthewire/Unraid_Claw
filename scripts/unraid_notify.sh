#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/unraid_common.sh"

require_command "jq" "required to build webhook payload"
require_command "curl" "required for webhook notification"
ensure_state_dirs

severity="${1:-INFO}"
message="${2:-Unraid notification event}"
host_label="${UNRAID_NOTIFY_HOST_LABEL:-$(hostname)}"
notify_timeout="${UNRAID_NOTIFY_TIMEOUT_SECONDS:-8}"
webhook_url="${UNRAID_NOTIFY_WEBHOOK_URL:-}"
log_file="${LOG_DIR}/notify.log"
timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if ! [[ "$notify_timeout" =~ ^[0-9]+$ ]]; then
  echo "FAIL: UNRAID_NOTIFY_TIMEOUT_SECONDS must be an integer."
  exit 2
fi

payload="$(jq -n \
  --arg timestamp "$timestamp" \
  --arg severity "$severity" \
  --arg message "$message" \
  --arg host "$host_label" \
  '{timestamp: $timestamp, severity: $severity, host: $host, message: $message}')"

if [[ -n "$webhook_url" ]]; then
  body_file="$(mktemp)"
  err_file="$(mktemp)"
  cleanup() {
    rm -f "$body_file" "$err_file"
  }
  trap cleanup EXIT

  http_code="$(curl -sS \
    --connect-timeout "$notify_timeout" \
    --max-time "$notify_timeout" \
    -o "$body_file" \
    -w "%{http_code}" \
    -X POST "$webhook_url" \
    -H "Content-Type: application/json" \
    --data "$payload" 2>"$err_file")"
  curl_status=$?

  if [[ $curl_status -ne 0 ]]; then
    echo "FAIL: Notification webhook request failed."
    echo "DETAIL: $(sanitize_error_file "$err_file")"
    echo "${timestamp} severity=${severity} host=${host_label} message=${message}" >> "$log_file"
    exit 3
  fi

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "FAIL: Notification webhook returned HTTP ${http_code}."
    echo "${timestamp} severity=${severity} host=${host_label} message=${message}" >> "$log_file"
    exit 5
  fi

  echo "PASS: Notification sent via webhook."
  exit 0
fi

echo "${timestamp} severity=${severity} host=${host_label} message=${message}" >> "$log_file"
echo "PASS: Notification written to local log (${log_file})."
exit 0