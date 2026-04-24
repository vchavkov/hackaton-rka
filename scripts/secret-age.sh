#!/usr/bin/env bash
# secret-age.sh — monitor secret age in Kubernetes namespace
#
# Detects secrets created/updated in the demo namespace and alerts if they
# exceed a configurable age threshold (default: 7 days).
#
# Usage:
#   ./scripts/secret-age.sh [OPTIONS]
#
# Options:
#   --namespace <ns>     Kubernetes namespace (default: demo)
#   --threshold-days <n> Age threshold in days (default: 7)
#   --alert-only         Only show secrets exceeding threshold
#   --json               Output as JSON
#   --sort-by-age        Sort by age (oldest first)

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-demo}"
THRESHOLD_DAYS=7
ALERT_ONLY=0
OUTPUT_JSON=0
SORT_BY_AGE=0

# ── helpers ───────────────────────────────────────────────────────────────────
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  \033[36m→\033[0m %s\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
alert() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
err()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    err "Required command not found: $1"
    exit 1
  fi
}

# Convert ISO 8601 timestamp to Unix seconds
iso8601_to_unix() {
  local ts="$1"
  date -d "$ts" +%s 2>/dev/null || echo "0"
}

# Convert Unix seconds to human-readable duration (e.g., "3 days, 5 hours")
unix_to_duration() {
  local seconds=$1
  local days=$(( seconds / 86400 ))
  local hours=$(( (seconds % 86400) / 3600 ))
  local mins=$(( (seconds % 3600) / 60 ))

  if [[ $days -gt 0 ]]; then
    printf "%d day%s, %d hour%s" \
      "$days" "$([ $days -eq 1 ] && echo "" || echo "s")" \
      "$hours" "$([ $hours -eq 1 ] && echo "" || echo "s")"
  elif [[ $hours -gt 0 ]]; then
    printf "%d hour%s, %d min%s" \
      "$hours" "$([ $hours -eq 1 ] && echo "" || echo "s")" \
      "$mins" "$([ $mins -eq 1 ] && echo "" || echo "s")"
  else
    printf "%d minute%s" \
      "$mins" "$([ $mins -eq 1 ] && echo "" || echo "s")"
  fi
}

# Parse command-line arguments
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --threshold-days)
        THRESHOLD_DAYS="$2"
        shift 2
        ;;
      --alert-only)
        ALERT_ONLY=1
        shift
        ;;
      --json)
        OUTPUT_JSON=1
        shift
        ;;
      --sort-by-age)
        SORT_BY_AGE=1
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        err "Unknown option: $1"
        exit 1
        ;;
    esac
  done
}

show_help() {
  cat <<EOF
Monitor secret age in Kubernetes namespace and alert on old secrets.

Usage:
  ./scripts/secret-age.sh [OPTIONS]

Options:
  --namespace <ns>     Kubernetes namespace (default: demo)
  --threshold-days <n> Age threshold in days (default: 7)
  --alert-only         Only show secrets exceeding threshold
  --json               Output as JSON
  --sort-by-age        Sort by age (oldest first)
  -h, --help           Show this help message

Examples:
  # Check secrets in demo namespace, alert on >7 days old
  ./scripts/secret-age.sh

  # Check demo namespace, alert on >30 days old
  ./scripts/secret-age.sh --threshold-days 30

  # Only show secrets that need rotation
  ./scripts/secret-age.sh --threshold-days 7 --alert-only

  # Export data for monitoring systems
  ./scripts/secret-age.sh --json --sort-by-age
EOF
}

# ── main ──────────────────────────────────────────────────────────────────────
cmd_check_age() {
  require_cmd kubectl
  require_cmd python3

  local now_unix
  now_unix="$(date +%s)"

  # Fetch all secrets from the namespace with metadata
  local secrets_json
  secrets_json="$(kubectl get secret -n "$NAMESPACE" -o json 2>/dev/null)" \
    || { err "Failed to query secrets in namespace: $NAMESPACE"; exit 1; }

  # Count total secrets
  local total_secrets
  total_secrets="$(printf '%s' "$secrets_json" | \
    python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))" 2>/dev/null || echo "0")"

  if [[ "$total_secrets" -eq 0 ]]; then
    warn "No secrets found in namespace: $NAMESPACE"
    return 1
  fi

  # Use temp file to avoid subshell issues with arrays
  local tmp_file
  tmp_file="$(mktemp)"
  trap "rm -f '$tmp_file'" RETURN

  # Fetch all secret timestamps and process them
  printf '%s' "$secrets_json" | python3 -c '
import sys, json, time as time_module
from datetime import datetime

now_unix = int(time_module.time())
threshold_seconds = '$THRESHOLD_DAYS' * 86400
secrets = json.load(sys.stdin)

for item in secrets.get("items", []):
    name = item["metadata"]["name"]
    creation_ts = item["metadata"].get("creationTimestamp", "")

    # Try to get the most recent update time from managedFields
    update_ts = creation_ts
    for mf in item["metadata"].get("managedFields", []):
        if mf.get("operation") in ["Update", "Apply"]:
            mf_time = mf.get("time", "")
            if mf_time > update_ts:
                update_ts = mf_time

    # Parse timestamp to unix seconds
    try:
        ts_dt = datetime.fromisoformat(update_ts.replace("Z", "+00:00"))
        ts_unix = int(ts_dt.timestamp())
    except:
        continue

    age_seconds = now_unix - ts_unix
    age_days = age_seconds // 86400
    exceeds_threshold = 1 if age_seconds > threshold_seconds else 0

    print(f"{name}|{age_seconds}|{age_days}|{update_ts}|{exceeds_threshold}")
' > "$tmp_file"

  # Build array from temp file and sort if needed
  local secrets_data=()
  mapfile -t secrets_data < "$tmp_file"

  if [[ $SORT_BY_AGE -eq 1 ]]; then
    printf '%s\n' "${secrets_data[@]}" | sort -t'|' -k2 -rn | mapfile -t secrets_data
  fi

  # Output results
  if [[ $OUTPUT_JSON -eq 1 ]]; then
    output_json "${secrets_data[@]}"
  else
    output_table "$total_secrets" "${secrets_data[@]}"
  fi
}

output_table() {
  local total_secrets="$1"
  shift
  local secrets_data=("$@")

  local threshold_seconds=$(( THRESHOLD_DAYS * 86400 ))
  local alert_count=0 ok_count=0

  bold "Secret Age Report — namespace: $NAMESPACE"
  printf '  Threshold: %d days  |  Total secrets: %d\n' "$THRESHOLD_DAYS" "$total_secrets"
  echo

  printf '\033[1m%-30s %-12s %-20s %s\033[0m\n' \
    "SECRET" "AGE (DAYS)" "LAST UPDATE" "STATUS"
  printf '%s\n' "──────────────────────────────────────────────────────────────────────"

  for data in "${secrets_data[@]}"; do
    IFS='|' read -r name age_seconds age_days ts_to_use exceeds_threshold <<< "$data"

    # Skip if alert-only and doesn't exceed threshold
    if [[ $ALERT_ONLY -eq 1 && $exceeds_threshold -eq 0 ]]; then
      ((ok_count++))
      continue
    fi

    local duration
    duration="$(unix_to_duration "$age_seconds")"

    if [[ $exceeds_threshold -eq 1 ]]; then
      printf '%-30s %-12s %-20s \033[31m✗ ROTATE\033[0m\n' \
        "${name:0:28}" "$age_days" "${ts_to_use:0:19}"
      ((alert_count++))
    else
      printf '%-30s %-12s %-20s \033[32m✓ ok\033[0m\n' \
        "${name:0:28}" "$age_days" "${ts_to_use:0:19}"
      ((ok_count++))
    fi
  done

  echo
  echo "Summary:"
  [[ $alert_count -eq 0 ]] && ok "All secrets within threshold" || alert "$alert_count secret(s) exceed $THRESHOLD_DAYS-day threshold"
  [[ $ok_count -gt 0 ]] && info "$ok_count secret(s) within threshold"
  echo
}

output_json() {
  local secrets_data=("$@")
  local threshold_seconds=$(( THRESHOLD_DAYS * 86400 ))

  printf '{\n'
  printf '  "namespace": "%s",\n' "$NAMESPACE"
  printf '  "threshold_days": %d,\n' "$THRESHOLD_DAYS"
  printf '  "checked_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "secrets": [\n'

  local first=1
  for data in "${secrets_data[@]}"; do
    IFS='|' read -r name age_seconds age_days ts_to_use exceeds_threshold <<< "$data"

    [[ $first -eq 0 ]] && printf ',\n'
    first=0

    printf '    {\n'
    printf '      "name": "%s",\n' "$name"
    printf '      "age_seconds": %d,\n' "$age_seconds"
    printf '      "age_days": %d,\n' "$age_days"
    printf '      "last_updated": "%s",\n' "$ts_to_use"
    printf '      "exceeds_threshold": %s\n' "$([ $exceeds_threshold -eq 1 ] && echo 'true' || echo 'false')"
    printf '    }'
  done

  printf '\n  ]\n'
  printf '}\n'
}

# ── entrypoint ────────────────────────────────────────────────────────────────
parse_args "$@"
cmd_check_age
