#!/usr/bin/env bash
# install-argocd.sh — install ArgoCD into a Kubernetes cluster
#
# Usage:
#   ./scripts/argocd.sh [install|ingress|uninstall|status|degraded|password|portforward]
#
# Env overrides:
#   ARGOCD_NAMESPACE  (default: argocd)
#   ARGOCD_VERSION    (default: stable)
#   ARGOCD_PASSWORD   (default: admin123!)
#   ARGOCD_PORT       (default: 8080)
#   DOMAIN            (default: demo.local)   — matches demo.sh
#   INGRESS_CLASS     (default: nginx)        — matches demo.sh

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
ARGOCD_PASSWORD="${ARGOCD_PASSWORD:-admin123!}"
ARGOCD_PORT="${ARGOCD_PORT:-8080}"
DOMAIN="${DOMAIN:-demo.local}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
ARGOCD_HOST="argocd.${DOMAIN}"

ARGOCD_INSTALL_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# ── helpers ───────────────────────────────────────────────────────────────────
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  \033[36m→\033[0m %s\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
sep()   { printf '%s\n' "────────────────────────────────────────────────────"; }

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    err "Required command not found: $1"
    exit 1
  fi
}

# ── install ───────────────────────────────────────────────────────────────────
cmd_install() {
  require_cmd kubectl

  # Install MetalLB if ingress controller has no external IP (kind clusters)
  if [[ -z "$(kubectl get svc -A \
        -l 'app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller' \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)" ]]; then
    warn "Ingress controller has no external IP — installing MetalLB..."
    echo
    "${SCRIPT_DIR}/demo.sh" metallb
  fi

  bold "Installing ArgoCD"
  info "namespace     : $ARGOCD_NAMESPACE"
  info "version       : $ARGOCD_VERSION"
  info "FQDN          : http://${ARGOCD_HOST}"
  info "ingressClass  : $INGRESS_CLASS"
  sep

  # Create namespace
  if kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    info "Namespace '$ARGOCD_NAMESPACE' already exists"
  else
    kubectl create namespace "$ARGOCD_NAMESPACE"
    ok "Created namespace: $ARGOCD_NAMESPACE"
  fi

  # Apply ArgoCD manifests
  # --server-side avoids the "annotations too long" error on large CRDs (applicationsets)
  info "Applying ArgoCD manifests ($ARGOCD_VERSION)..."
  kubectl apply -n "$ARGOCD_NAMESPACE" --server-side -f "$ARGOCD_INSTALL_MANIFEST"
  echo

  # Wait for ArgoCD server to be ready
  info "Waiting for ArgoCD server to be ready (up to 3 minutes)..."
  kubectl rollout status deployment/argocd-server \
    -n "$ARGOCD_NAMESPACE" \
    --timeout=180s
  ok "ArgoCD server is ready"
  echo

  # Set the admin password
  cmd_set_password

  # Create ingress
  cmd_ingress
  sep

  bold "ArgoCD installed successfully!"
  echo
  info "FQDN:      http://${ARGOCD_HOST}"
  info "Username:  admin"
  info "Password:  ${ARGOCD_PASSWORD}"
  echo
  if [[ "$DOMAIN" != *.nip.io ]]; then
    "${SCRIPT_DIR}/demo.sh" dns
  fi
  echo
  info "Fallback port-forward:  ./scripts/install-argocd.sh portforward"
  echo
}

# ── set password ──────────────────────────────────────────────────────────────
cmd_set_password() {
  require_cmd kubectl

  bold "Setting admin password"

  # Hash the password using bcrypt (cost 10, as ArgoCD expects)
  local hashed=""

  if command -v htpasswd &>/dev/null; then
    hashed="$(htpasswd -nbBC 10 "" "$ARGOCD_PASSWORD" | tr -d ':\n' | sed 's/^!//')"
  elif command -v python3 &>/dev/null && python3 -c "import bcrypt" 2>/dev/null; then
    hashed="$(python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt(rounds=10)).decode())
" "$ARGOCD_PASSWORD")"
  else
    err "Neither 'htpasswd' (apache2-utils) nor python3 'bcrypt' module found."
    err "Install one of them and re-run:  ./scripts/install-argocd.sh password"
    exit 1
  fi

  # Patch the argocd-secret with the new bcrypt hash
  local now
  now="$(date -u +%FT%TZ)"

  kubectl -n "$ARGOCD_NAMESPACE" patch secret argocd-secret \
    --type=merge \
    -p "{\"stringData\":{\"admin.password\":\"${hashed}\",\"admin.passwordMtime\":\"${now}\"}}"

  ok "Admin password set to: ${ARGOCD_PASSWORD}"

  # Force argocd-server to pick up the new secret
  kubectl -n "$ARGOCD_NAMESPACE" rollout restart deployment/argocd-server &>/dev/null
  info "argocd-server restarting to apply new credentials..."
  kubectl rollout status deployment/argocd-server \
    -n "$ARGOCD_NAMESPACE" \
    --timeout=60s
  ok "argocd-server ready"
}

# ── ingress ───────────────────────────────────────────────────────────────────
cmd_ingress() {
  require_cmd kubectl

  bold "Configuring ingress → http://${ARGOCD_HOST}"

  # Tell argocd-server to serve plain HTTP so the ingress controller can
  # forward traffic without TLS passthrough.
  kubectl -n "$ARGOCD_NAMESPACE" patch configmap argocd-cmd-params-cm \
    --type=merge \
    -p '{"data":{"server.insecure":"true"}}' 2>/dev/null || \
  kubectl -n "$ARGOCD_NAMESPACE" create configmap argocd-cmd-params-cm \
    --from-literal=server.insecure=true

  ok "argocd-server set to insecure (HTTP) mode"

  # Set repo poll interval to 60s (default is 3 min) so rotations are picked
  # up within a minute of the git push.
  kubectl -n "$ARGOCD_NAMESPACE" patch configmap argocd-cm \
    --type=merge \
    -p '{"data":{"timeout.reconciliation":"60s"}}'
  ok "ArgoCD repo poll interval set to 60s"

  # Apply Ingress resource
  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: ${ARGOCD_NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
  - host: ${ARGOCD_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF

  ok "Ingress created: ${ARGOCD_HOST}"

  # Restart argocd-server to pick up the insecure flag
  kubectl -n "$ARGOCD_NAMESPACE" rollout restart deployment/argocd-server &>/dev/null
  kubectl rollout status deployment/argocd-server \
    -n "$ARGOCD_NAMESPACE" \
    --timeout=60s
  ok "argocd-server restarted in HTTP mode"
}

# ── portforward ───────────────────────────────────────────────────────────────
cmd_portforward() {
  require_cmd kubectl

  bold "Port-forwarding ArgoCD UI → http://localhost:${ARGOCD_PORT}  (Ctrl-C to stop)"
  sep
  info "FQDN (via ingress): http://${ARGOCD_HOST}"
  info "Localhost fallback: http://localhost:${ARGOCD_PORT}"
  info "Username:           admin"
  info "Password:           ${ARGOCD_PASSWORD}"
  echo

  kubectl port-forward svc/argocd-server \
    -n "$ARGOCD_NAMESPACE" \
    "${ARGOCD_PORT}:80"
}

# ── status ────────────────────────────────────────────────────────────────────
cmd_status() {
  require_cmd kubectl

  bold "ArgoCD status — namespace: $ARGOCD_NAMESPACE"
  sep

  if ! kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    warn "Namespace '$ARGOCD_NAMESPACE' not found — ArgoCD is not installed."
    return
  fi

  kubectl get pods -n "$ARGOCD_NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount' \
    2>/dev/null || kubectl get pods -n "$ARGOCD_NAMESPACE"
  echo
  kubectl get svc -n "$ARGOCD_NAMESPACE" 2>/dev/null
  echo
}

# ── degraded apps ─────────────────────────────────────────────────────────────
cmd_degraded() {
  require_cmd kubectl

  bold "ArgoCD degraded applications — namespace: $ARGOCD_NAMESPACE"
  sep

  if ! kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    warn "Namespace '$ARGOCD_NAMESPACE' not found — ArgoCD is not installed."
    return
  fi

  kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io \
    --field-selector=status.health.status=Degraded \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.operationState.phase,HEALTH:.status.health.status,SYNC:.status.sync.status' \
    2>/dev/null || kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io \
    --field-selector=status.health.status=Degraded

  local count
  count=$(kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io \
    --field-selector=status.health.status=Degraded \
    --no-headers 2>/dev/null | wc -l)

  if [[ $count -eq 0 ]]; then
    ok "No degraded applications found"
  else
    warn "Found $count degraded application(s)"
  fi
}

# ── unhealthy apps ────────────────────────────────────────────────────────────
# Prints all applications whose health is anything other than "Healthy".
# Covers: Degraded, Progressing (stuck), Missing, Suspended, Unknown.
cmd_unhealthy() {
  require_cmd kubectl

  bold "ArgoCD unhealthy applications — namespace: $ARGOCD_NAMESPACE"
  sep

  if ! kubectl get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    warn "Namespace '$ARGOCD_NAMESPACE' not found — ArgoCD is not installed."
    return
  fi

  local all_apps
  all_apps="$(kubectl -n "$ARGOCD_NAMESPACE" get applications.argoproj.io \
    -o json 2>/dev/null)" || {
    err "Failed to list ArgoCD applications."
    exit 1
  }

  local count=0
  printf '\033[1m%-24s %-14s %-12s %s\033[0m\n' "NAME" "HEALTH" "SYNC" "MESSAGE"
  printf '%s\n' "────────────────────────────────────────────────────────────────────"

  while IFS= read -r line; do
    local name health sync message
    name="$(    printf '%s' "$line" | cut -d'|' -f1)"
    health="$(  printf '%s' "$line" | cut -d'|' -f2)"
    sync="$(    printf '%s' "$line" | cut -d'|' -f3)"
    message="$( printf '%s' "$line" | cut -d'|' -f4)"

    [[ "$health" == "Healthy" ]] && continue

    local color
    case "$health" in
      Degraded)    color='\033[31m' ;;   # red
      Progressing) color='\033[33m' ;;   # yellow
      Missing)     color='\033[35m' ;;   # magenta
      Suspended)   color='\033[36m' ;;   # cyan
      *)           color='\033[0m'  ;;   # default
    esac

    printf "%-24s ${color}%-14s\033[0m %-12s %s\n" \
      "$name" "$health" "$sync" "${message:0:60}"
    (( count++ )) || true
  done < <(printf '%s' "$all_apps" | python3 -c "
import sys, json
apps = json.load(sys.stdin).get('items', [])
for a in apps:
    name    = a['metadata']['name']
    health  = a.get('status', {}).get('health', {}).get('status', 'Unknown')
    sync    = a.get('status', {}).get('sync',   {}).get('status', 'Unknown')
    message = a.get('status', {}).get('health', {}).get('message', '')
    print(f'{name}|{health}|{sync}|{message}')
" 2>/dev/null)

  echo
  if [[ $count -eq 0 ]]; then
    ok "All applications are Healthy"
  else
    warn "$count unhealthy application(s) found"
  fi
}

# ── teardown / uninstall ──────────────────────────────────────────────────────
cmd_teardown() {
  require_cmd kubectl

  bold "Tearing down ArgoCD from namespace: $ARGOCD_NAMESPACE"
  sep

  info "Removing ArgoCD manifests..."
  kubectl delete -n "$ARGOCD_NAMESPACE" -f "$ARGOCD_INSTALL_MANIFEST" --ignore-not-found
  # Also remove the ingress we created separately
  kubectl delete ingress argocd-server -n "$ARGOCD_NAMESPACE" --ignore-not-found 2>/dev/null || true
  ok "Resources removed"
  echo
  ok "ArgoCD torn down."
}

cmd_uninstall() {
  bold "Uninstalling ArgoCD from namespace: $ARGOCD_NAMESPACE"
  warn "This will delete all ArgoCD resources and the namespace!"
  printf '\033[1mContinue? [y/N]\033[0m '
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
  cmd_teardown
}

# ── entrypoint ────────────────────────────────────────────────────────────────
case "${1:-install}" in
  install)     cmd_install      ;;
  ingress)     cmd_ingress      ;;
  password)    cmd_set_password ;;
  portforward) cmd_portforward  ;;
  status)      cmd_status       ;;
  degraded)    cmd_degraded     ;;
  unhealthy)   cmd_unhealthy    ;;
  teardown)    cmd_teardown     ;;
  uninstall)   cmd_uninstall    ;;
  *)
    bold "Usage: $0 [install|ingress|password|portforward|status|degraded|unhealthy|teardown|uninstall]"
    echo
    echo "  install      — deploy ArgoCD, set password, and configure ingress"
    echo "  ingress      — (re-)apply ingress for http://${ARGOCD_HOST}"
    echo "  password     — (re-)set the admin password on an existing install"
    echo "  portforward  — fallback: forward argocd-server to localhost:${ARGOCD_PORT}"
    echo "  status       — show pod and service status"
    echo "  degraded     — list applications with Degraded health status"
    echo "  unhealthy    — list all applications that are not Healthy"
    echo "  teardown     — remove ArgoCD and its namespace (no confirmation)"
    echo "  uninstall    — same as teardown but asks for confirmation"
    echo
    echo "Env vars: ARGOCD_NAMESPACE  ARGOCD_VERSION  ARGOCD_PASSWORD  ARGOCD_PORT"
    echo "          DOMAIN (default: demo.local)  INGRESS_CLASS (default: nginx)"
    exit 1
    ;;
esac
