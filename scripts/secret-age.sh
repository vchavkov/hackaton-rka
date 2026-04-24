#!/usr/bin/env bash
# secret-age.sh — monitor, rotate and clean up Kubernetes secrets
#
# Detects secrets created/updated in the demo namespace and alerts if they
# exceed a configurable age threshold (default: 7 days).
#
# Default action depends on the namespace:
#   - namespace == "demo"  → rotate the oldest secret via ArgoCD
#   - any other namespace  → check & report secret ages
#
# Override with --rotate / --no-rotate, or use --cleanup to delete unused
# secrets (stale Helm release history + secrets not referenced by any pod,
# controller, ServiceAccount or Ingress).

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
THRESHOLD_DAYS=7
ALERT_ONLY=0
OUTPUT_JSON=0
SORT_BY_AGE=0
# ROTATE: -1 = unset (decide from namespace), 0 = check only, 1 = rotate
ROTATE=-1
# ACTION: empty = decide from ROTATE/namespace, "cleanup" = delete unused
ACTION=""
DRY_RUN=0
INCLUDE_UNREFERENCED=0

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
      --argocd-namespace)
        ARGOCD_NAMESPACE="$2"
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
      --rotate)
        ROTATE=1
        shift
        ;;
      --no-rotate)
        ROTATE=0
        shift
        ;;
      --cleanup)
        ACTION="cleanup"
        shift
        ;;
      --include-unreferenced)
        INCLUDE_UNREFERENCED=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
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

Default action:
  When --namespace is "demo" (the default), the oldest secret is rotated via
  ArgoCD. For any other namespace, the script only reports secret ages.
  Use --rotate / --no-rotate to override this default, or --cleanup to
  delete unused secrets instead.

Options:
  --namespace <ns>          Kubernetes namespace (default: demo)
  --argocd-namespace <ns>   ArgoCD namespace (default: argocd)
  --threshold-days <n>      Age threshold in days (default: 7)
  --alert-only              Only show secrets exceeding threshold
  --json                    Output as JSON
  --sort-by-age             Sort by age (oldest first)
  --rotate                  Force rotation of the oldest secret via ArgoCD
  --no-rotate               Force check-only (skip rotation, even on 'demo')
  --cleanup                 Delete stale Helm release-history secrets (safe:
                            Helm only needs the latest revision per release).
                            Add --include-unreferenced to be more aggressive.
  --include-unreferenced    With --cleanup: also delete secrets not referenced
                            by any pod/controller/SA/Ingress, with skip rules
                            for argocd-* and managed-by/part-of labels.
  --dry-run                 With --cleanup: list candidates without deleting
  -h, --help                Show this help message

Examples:
  # Default: rotate the oldest secret in 'demo' via ArgoCD
  ./scripts/secret-age.sh

  # Inspect 'demo' without rotating
  ./scripts/secret-age.sh --no-rotate

  # Check another namespace, 30-day threshold (no rotation by default)
  ./scripts/secret-age.sh --namespace prod --threshold-days 30

  # Only show secrets that need rotation
  ./scripts/secret-age.sh --no-rotate --alert-only

  # Export data for monitoring systems
  ./scripts/secret-age.sh --no-rotate --json --sort-by-age

  # Force rotation in a non-default namespace
  ./scripts/secret-age.sh --namespace staging --rotate

  # Preview stale Helm history secrets in 'demo' without deleting
  ./scripts/secret-age.sh --cleanup --dry-run

  # Delete stale Helm history secrets in 'demo'
  ./scripts/secret-age.sh --cleanup

  # Also include unreferenced secrets (skips argocd-*, managed-by/part-of)
  ./scripts/secret-age.sh --cleanup --include-unreferenced --dry-run
EOF
}

# ── rotate oldest secret ──────────────────────────────────────────────────────
cmd_rotate() {
  require_cmd kubectl
  require_cmd python3

  bold "Finding oldest secret — namespace: $NAMESPACE"

  local now_unix
  now_unix="$(date +%s)"

  # Fetch secrets managed by the key-rotation-agent chart
  local secrets_json
  secrets_json="$(kubectl get secret -n "$NAMESPACE" \
    -l 'app.kubernetes.io/name=key-rotation-agent' -o json 2>/dev/null)" \
    || { err "Failed to query secrets in namespace: $NAMESPACE"; exit 1; }

  # Find the oldest secret; emit: name|release|age_seconds|last_ts
  # Pass JSON via env var because `python3 -` reads its script from stdin and
  # would collide with a piped payload.
  local oldest
  oldest="$(SECRETS_JSON="$secrets_json" NOW_UNIX="$now_unix" python3 - <<'PYEOF'
import os, json
from datetime import datetime

now_unix = int(os.environ["NOW_UNIX"])
data = json.loads(os.environ["SECRETS_JSON"])

best = None
best_age = -1

for item in data.get("items", []):
    name = item["metadata"]["name"]
    release = item["metadata"].get("labels", {}).get("app.kubernetes.io/instance", "")
    if not release:
        continue

    ts = item["metadata"].get("creationTimestamp", "")
    for mf in item["metadata"].get("managedFields", []):
        if mf.get("operation") in ("Update", "Apply") and mf.get("time", "") > ts:
            ts = mf["time"]

    try:
        age = now_unix - int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp())
    except Exception:
        continue

    if age > best_age:
        best_age = age
        best = f"{name}|{release}|{age}|{ts}"

if best:
    print(best)
PYEOF
)"

  if [[ -z "$oldest" ]]; then
    err "No secrets found with label app.kubernetes.io/name=key-rotation-agent in $NAMESPACE"
    exit 1
  fi

  local secret_name release age_secs last_ts
  IFS='|' read -r secret_name release age_secs last_ts <<< "$oldest"

  info "Oldest secret : $secret_name"
  info "Release       : $release"
  info "Age           : $(unix_to_duration "$age_secs") (last updated: ${last_ts:0:19})"
  echo

  # Fetch current ArgoCD Application to preserve color and ingress settings
  local app_json
  app_json="$(kubectl get application "$release" -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)" \
    || { err "ArgoCD Application '$release' not found in namespace '$ARGOCD_NAMESPACE'"; exit 1; }

  # Extract preserved fields from current helm values
  local preserved
  preserved="$(APP_JSON="$app_json" python3 - <<'PYEOF'
import os, json, re

data = json.loads(os.environ["APP_JSON"])
vals = data["spec"]["source"]["helm"].get("values", "")

def extract(pattern, text, default=""):
    m = re.search(pattern, text, re.MULTILINE)
    return m.group(1).strip().strip("\"' ") if m else default

color     = extract(r'^\s+color:\s*["\']?([^"\'\n]+)["\']?', vals, "#000000")
host      = extract(r'^\s+host:\s*["\']?([^"\'\n]+)["\']?',  vals, "")
cls       = extract(r'className:\s*["\']?([^"\'\n]+)["\']?',  vals, "nginx")

print(f"{color}|{host}|{cls}")
PYEOF
)"

  local color hostname ingress_class
  IFS='|' read -r color hostname ingress_class <<< "$preserved"

  # Generate new credentials. Using python instead of `tr | head` avoids
  # SIGPIPE killing the pipeline under `set -o pipefail` when head closes
  # its stdin early.
  local db_password db_password_fmt updated_at
  db_password="$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))')"
  db_password_fmt="$(printf '%s' "$db_password" | sed 's/.\{8\}/&-/g; s/-$//')"
  updated_at="$(date -u '+%Y-%m-%d %H:%M UTC')"

  # Build replacement helm values YAML
  local new_values
  new_values="$(cat <<YAML
podinfo:
  color: "${color}"
  message: |
    Updated:      ${updated_at}
    DB_PASSWORD:  ${db_password_fmt}
secret:
  data:
    DB_PASSWORD: "${db_password}"
ingress:
  enabled: true
  className: "${ingress_class}"
  hosts:
    - host: "${hostname}"
      paths:
        - path: /
          pathType: Prefix
YAML
)"

  # JSON-encode the values string for the patch payload
  local values_json
  values_json="$(NEW_VALUES="$new_values" python3 -c 'import os,json; print(json.dumps(os.environ["NEW_VALUES"]))')"

  # Patch values AND clear ignoreDifferences in one go.
  # The Application was deployed with ignoreDifferences on
  # /spec/template/metadata/annotations/checksum~1secret, which made ArgoCD
  # treat the chart's `checksum/secret` annotation as in-sync even after the
  # Secret changed — so the Deployment never got re-applied and pods never
  # rolled. Setting ignoreDifferences to [] re-enables the chart's built-in
  # restart-on-secret-change mechanism.
  kubectl patch application "$release" \
    -n "$ARGOCD_NAMESPACE" \
    --type=merge \
    -p "{\"spec\":{\"source\":{\"helm\":{\"values\":${values_json}}},\"ignoreDifferences\":[]}}"

  echo
  ok "Rotated: $release"
  info "New DB_PASSWORD : $db_password_fmt"
  info "ArgoCD will sync; the chart's checksum/secret annotation will trigger a rolling restart"

  # Belt-and-suspenders: explicitly bump the deployment so the rolling
  # restart kicks off immediately even if ArgoCD takes a few seconds to
  # observe the diff. ArgoCD's selfHeal will not undo this — the new
  # checksum annotation will match what the chart re-renders.
  local deploy_name
  deploy_name="$(kubectl get deployment -n "$NAMESPACE" \
    -l "app.kubernetes.io/instance=${release}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$deploy_name" ]]; then
    kubectl -n "$NAMESPACE" rollout restart "deployment/${deploy_name}" >/dev/null
    info "Rolling restart triggered: deployment/${deploy_name}"
  fi
}

# ── cleanup unused secrets ────────────────────────────────────────────────────
# Identifies secrets that are not referenced by any pod, controller pod
# template, ServiceAccount or Ingress, plus stale Helm release-history
# secrets (sh.helm.release.v1.<release>.v<N> where N is not the latest
# revision for that release). Optionally deletes them.
cmd_cleanup() {
  require_cmd kubectl
  require_cmd python3

  bold "Scanning for unused secrets — namespace: $NAMESPACE"
  if [[ $INCLUDE_UNREFERENCED -eq 1 ]]; then
    info "Mode: stale Helm history + unreferenced (with controller skip rules)"
  else
    info "Mode: stale Helm history only (use --include-unreferenced for more)"
  fi

  # Discover unused secrets in one python invocation (calls kubectl itself).
  # Emits one line per candidate as: <name>|<reason>
  local plan_file
  plan_file="$(mktemp)"
  trap "rm -f '$plan_file'" RETURN

  KRA_NAMESPACE="$NAMESPACE" \
  KRA_INCLUDE_UNREFERENCED="$INCLUDE_UNREFERENCED" \
  python3 - "$plan_file" <<'PYEOF'
import os, sys, json, re, subprocess

ns = os.environ["KRA_NAMESPACE"]
include_unreferenced = os.environ.get("KRA_INCLUDE_UNREFERENCED") == "1"

# Names / prefixes / labels that mark a secret as managed by a controller
# we shouldn't touch even if no pod references it directly.
PROTECTED_PREFIXES = ("argocd-",)
PROTECTED_LABELS = ("app.kubernetes.io/part-of", "app.kubernetes.io/managed-by")
PROTECTED_ANNOTATIONS = ("meta.helm.sh/release-name",)

def kget(kind):
    try:
        out = subprocess.check_output(
            ["kubectl", "-n", ns, "get", kind, "-o", "json"],
            stderr=subprocess.DEVNULL,
        )
        return json.loads(out).get("items", [])
    except Exception:
        return []

secrets = {s["metadata"]["name"]: s for s in kget("secrets")}
sa_items = kget("serviceaccounts")
sa_names = {sa["metadata"]["name"] for sa in sa_items}

referenced = set()

def scan_pod_spec(spec):
    if not spec:
        return
    for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
        for env in c.get("env") or []:
            ref = (env.get("valueFrom") or {}).get("secretKeyRef", {}).get("name")
            if ref:
                referenced.add(ref)
        for ef in c.get("envFrom") or []:
            ref = (ef.get("secretRef") or {}).get("name")
            if ref:
                referenced.add(ref)
    for v in spec.get("volumes") or []:
        ref = (v.get("secret") or {}).get("secretName")
        if ref:
            referenced.add(ref)
        for src in (v.get("projected") or {}).get("sources") or []:
            ref = (src.get("secret") or {}).get("name")
            if ref:
                referenced.add(ref)
    for ips in spec.get("imagePullSecrets") or []:
        if ips.get("name"):
            referenced.add(ips["name"])

for p in kget("pods"):
    scan_pod_spec(p.get("spec"))

for kind in ("deployments", "statefulsets", "daemonsets", "replicasets", "jobs"):
    for item in kget(kind):
        scan_pod_spec(((item.get("spec") or {}).get("template") or {}).get("spec"))

for cj in kget("cronjobs"):
    tmpl = (((cj.get("spec") or {}).get("jobTemplate") or {})
            .get("spec", {}).get("template", {}).get("spec"))
    scan_pod_spec(tmpl)

for sa in sa_items:
    for s in sa.get("secrets") or []:
        if s.get("name"):
            referenced.add(s["name"])
    for s in sa.get("imagePullSecrets") or []:
        if s.get("name"):
            referenced.add(s["name"])

for ing in kget("ingresses"):
    for tls in (ing.get("spec") or {}).get("tls") or []:
        if tls.get("secretName"):
            referenced.add(tls["secretName"])

# Helm release history: keep latest revision per release, mark older as stale.
helm_re = re.compile(r"^sh\.helm\.release\.v1\.(.+)\.v(\d+)$")
helm_latest, helm_secrets = {}, []
for name, sec in secrets.items():
    if sec.get("type") == "helm.sh/release.v1":
        m = helm_re.match(name)
        if m:
            release, ver = m.group(1), int(m.group(2))
            helm_secrets.append((name, release, ver))
            if ver > helm_latest.get(release, 0):
                helm_latest[release] = ver
helm_stale = {n for n, r, v in helm_secrets if v != helm_latest.get(r)}

candidates = []
for name, sec in secrets.items():
    annotations = sec["metadata"].get("annotations") or {}
    labels = sec["metadata"].get("labels") or {}
    if annotations.get("helm.sh/resource-policy") == "keep":
        continue

    # Always-safe deletion: stale helm release history.
    if name in helm_stale:
        candidates.append((name, "stale Helm history"))
        continue

    # Anything beyond Helm history requires explicit opt-in.
    if not include_unreferenced:
        continue

    stype = sec.get("type", "")
    if stype == "helm.sh/release.v1":
        continue  # latest revision, still tracked

    if stype == "kubernetes.io/service-account-token":
        sa = annotations.get("kubernetes.io/service-account.name")
        if sa and sa in sa_names:
            continue
        candidates.append((name, "orphaned SA token"))
        continue

    if name in referenced:
        continue

    # Skip secrets that look controller-owned even if no pod references them.
    if any(name.startswith(p) for p in PROTECTED_PREFIXES):
        continue
    if any(k in labels for k in PROTECTED_LABELS):
        continue
    if any(k in annotations for k in PROTECTED_ANNOTATIONS):
        continue

    candidates.append((name, f"unreferenced ({stype or 'Opaque'})"))

with open(sys.argv[1], "w") as fh:
    for name, reason in candidates:
        fh.write(f"{name}|{reason}\n")
PYEOF

  local count
  count="$(wc -l < "$plan_file" | tr -d ' ')"

  if [[ "$count" -eq 0 ]]; then
    ok "No unused secrets found"
    return 0
  fi

  echo
  printf '\033[1m%-40s %s\033[0m\n' "SECRET" "REASON"
  printf '%s\n' "──────────────────────────────────────────────────────────────────────"
  while IFS='|' read -r name reason; do
    printf '%-40s %s\n' "${name:0:38}" "$reason"
  done < "$plan_file"
  echo

  if [[ $DRY_RUN -eq 1 ]]; then
    info "$count secret(s) would be deleted (dry-run; pass without --dry-run to apply)"
    return 0
  fi

  warn "Deleting $count secret(s) from namespace $NAMESPACE"
  local names
  names="$(cut -d'|' -f1 "$plan_file" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kubectl delete secret -n "$NAMESPACE" $names
  echo
  ok "Deleted $count secret(s)"
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

    # Skip if alert-only and doesn't exceed threshold.
    # Use $((...)) form so a pre-increment from 0 doesn't trip `set -e`.
    if [[ $ALERT_ONLY -eq 1 && $exceeds_threshold -eq 0 ]]; then
      ok_count=$((ok_count + 1))
      continue
    fi

    local duration
    duration="$(unix_to_duration "$age_seconds")"

    if [[ $exceeds_threshold -eq 1 ]]; then
      printf '%-30s %-12s %-20s \033[31m✗ ROTATE\033[0m\n' \
        "${name:0:28}" "$age_days" "${ts_to_use:0:19}"
      alert_count=$((alert_count + 1))
    else
      printf '%-30s %-12s %-20s \033[32m✓ ok\033[0m\n' \
        "${name:0:28}" "$age_days" "${ts_to_use:0:19}"
      ok_count=$((ok_count + 1))
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

# --cleanup is an explicit action and bypasses the rotate/check default.
if [[ "$ACTION" == "cleanup" ]]; then
  cmd_cleanup
  exit 0
fi

# Resolve default action when --rotate / --no-rotate weren't given:
# rotate by default for the 'demo' namespace, check-only otherwise.
if [[ $ROTATE -eq -1 ]]; then
  if [[ "$NAMESPACE" == "demo" ]]; then
    ROTATE=1
  else
    ROTATE=0
  fi
fi

if [[ $ROTATE -eq 1 ]]; then
  cmd_rotate
else
  cmd_check_age
fi
