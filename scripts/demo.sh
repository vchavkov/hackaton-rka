#!/usr/bin/env bash
# demo.sh — deploy / dns / hosts / teardown / status / portforward
#
# Usage:
#   ./scripts/demo.sh [deploy|dns|hosts|teardown|status|portforward]
#
# Env overrides:
#   NAMESPACE     (default: demo)
#   DOMAIN        (default: demo.local)
#   INGRESS_CLASS (default: nginx)
#   DNSMASQ_CONF  (default: /etc/dnsmasq.conf)

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../helm"
NAMESPACE="${NAMESPACE:-demo}"
DOMAIN="${DOMAIN:-demo.local}"  # override with nip.io if no local DNS: DOMAIN=<ip>.nip.io
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"

RELEASES=(kra-alpha kra-beta kra-gamma kra-delta)
COLORS=("#e91e63" "#4caf50" "#ff9800" "#9c27b0")

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
HOSTS_MARKER_START="# kra-demo-start managed by demo.sh"
HOSTS_MARKER_END="# kra-demo-end"
DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/dnsmasq.conf}"
DNSMASQ_MARKER="# kra-demo managed by demo.sh"

# ── helpers ───────────────────────────────────────────────────────────────────
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  \033[36m→\033[0m %s\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
sep()   { printf '%s\n' "────────────────────────────────────────────────────"; }

rand_hex() { openssl rand -hex "${1:-16}"; }

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    err "Required command not found: $1"
    exit 1
  fi
}

# Return the Kubernetes service name for a release
svc_name() { echo "${1}-key-rotation-agent"; }

# Return the expected hostname for a release (DOMAIN must be set)
release_host() { echo "${1}.${DOMAIN}"; }

# Detect the ingress controller's external IP before any ingresses are created.
# Works with ingress-nginx, traefik (k3s), and bare-metal / minikube / kind.
get_controller_ip() {
  local ip=""

  # ingress-nginx LoadBalancer service
  ip="$(kubectl get svc -A \
        -l 'app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller' \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$ip" ]] && echo "$ip" && return

  # traefik LoadBalancer service (k3s default)
  ip="$(kubectl get svc -A \
        -l 'app.kubernetes.io/name=traefik' \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$ip" ]] && echo "$ip" && return

  # any LoadBalancer in common ingress namespaces
  for ns in ingress-nginx traefik kube-system; do
    ip="$(kubectl get svc -n "$ns" --field-selector spec.type=LoadBalancer \
          -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$ip" ]] && echo "$ip" && return
  done

  # minikube / kind — node internal IP
  ip="$(kubectl get nodes \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
        2>/dev/null || true)"
  [[ -n "$ip" ]] && echo "$ip" && return

  echo ""
}

# Detect IP from the deployed ingress objects (post-deploy)
get_ingress_ip() {
  local ingress_name
  ingress_name="$(svc_name "${RELEASES[0]}")"
  local ip=""

  ip="$(kubectl get ingress "$ingress_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$ip" ]] && echo "$ip" && return

  # AWS ALB / GKE — hostname instead of IP
  ip="$(kubectl get ingress "$ingress_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$ip" ]] && echo "$ip" && return

  get_controller_ip
}

# Returns true if the ingress-nginx controller LB IP is still <pending>
ingress_lb_pending() {
  local ip
  ip="$(kubectl get svc -A \
        -l 'app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller' \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -z "$ip" ]]
}

# ── metallb ───────────────────────────────────────────────────────────────────
cmd_metallb() {
  require_cmd kubectl
  require_cmd docker

  bold "Installing MetalLB (LoadBalancer support for kind)"
  sep

  # Detect the kind docker network subnet (e.g. 172.18.0.0/16)
  local subnet
  subnet="$(docker network inspect kind 2>/dev/null | \
    python3 -c "
import sys, json
for n in json.load(sys.stdin):
    for c in n.get('IPAM',{}).get('Config',[]):
        s = c.get('Subnet','')
        if '.' in s:
            print(s)
            break
" 2>/dev/null | head -1 || true)"

  if [[ -z "$subnet" ]]; then
    err "Could not detect kind docker network subnet."
    err "Is kind running?  docker network inspect kind"
    exit 1
  fi

  # Allocate last /24 of the subnet for MetalLB
  # e.g. 172.18.0.0/16 → 172.18.255.200-172.18.255.250
  local base
  base="$(echo "$subnet" | cut -d. -f1-2)"
  local pool="${base}.255.200-${base}.255.250"

  info "kind subnet : $subnet"
  info "MetalLB pool: $pool"
  echo

  # Install MetalLB
  info "Applying MetalLB manifests..."
  kubectl apply -f \
    https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml \
    2>&1 | grep -E '(created|configured|unchanged)' | sed 's/^/    /' || true

  # Wait for controller and speaker
  info "Waiting for MetalLB pods..."
  kubectl wait --namespace metallb-system \
    --for=condition=ready pod \
    --selector=app=metallb \
    --timeout=90s
  ok "MetalLB pods ready"
  echo

  # Configure IP pool + L2 advertisement
  kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${pool}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF

  ok "IPAddressPool configured: $pool"
  echo

  # Wait for ingress-nginx to pick up an external IP
  info "Waiting for ingress-nginx LoadBalancer IP (up to 30s)..."
  local assigned=""
  for _i in $(seq 1 10); do
    assigned="$(kubectl get svc -A \
      -l 'app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller' \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$assigned" ]] && break
    sleep 3
  done

  if [[ -n "$assigned" ]]; then
    ok "Ingress controller IP: $assigned"
  else
    warn "IP not yet assigned — run './scripts/demo.sh dns' once it appears."
  fi
  echo
}

# ── deploy ────────────────────────────────────────────────────────────────────
cmd_deploy() {
  require_cmd openssl
  require_cmd kubectl

  # On kind clusters the ingress-nginx LoadBalancer stays <pending> without
  # MetalLB — detect and fix automatically before deploying.
  if ingress_lb_pending; then
    warn "Ingress controller has no external IP — installing MetalLB..."
    echo
    cmd_metallb
  fi

  # ArgoCD needs a git remote to pull the chart from
  local git_url git_revision
  git_url="$(git -C "${SCRIPT_DIR}/.." remote get-url origin 2>/dev/null || true)"
  git_revision="$(git -C "${SCRIPT_DIR}/.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'HEAD')"
  if [[ -z "$git_url" ]]; then
    err "No git remote found. ArgoCD requires a git repository URL."
    err "Push your repo and try again, or set: git remote add origin <url>"
    exit 1
  fi

  bold "Deploying ${#RELEASES[@]} releases via ArgoCD"
  info "namespace    : $NAMESPACE"
  info "argocd ns    : $ARGOCD_NAMESPACE"
  info "domain       : $DOMAIN"
  info "ingressClass : $INGRESS_CLASS"
  info "git source   : $git_url @ $git_revision"
  sep

  for i in "${!RELEASES[@]}"; do
    local release="${RELEASES[$i]}"
    local color="${COLORS[$i]}"
    local hostname
    hostname="$(release_host "$release")"

    local api_key;       api_key="$(rand_hex 16)"
    local db_password;   db_password="$(rand_hex 16)"
    local webhook_token; webhook_token="$(rand_hex 12)"
    local updated_at;    updated_at="$(date -u '+%Y-%m-%d %H:%M UTC')"

    local api_key_fmt db_password_fmt webhook_token_fmt
    api_key_fmt="$(echo "$api_key"         | sed 's/.\{8\}/&-/g; s/-$//')"
    db_password_fmt="$(echo "$db_password" | sed 's/.\{8\}/&-/g; s/-$//')"
    webhook_token_fmt="$(echo "$webhook_token" | sed 's/.\{8\}/&-/g; s/-$//')"

    bold "[$((i+1))/${#RELEASES[@]}] $release  →  http://${hostname}"
    info "API_KEY       = $api_key_fmt"
    info "DB_PASSWORD   = $db_password_fmt"
    info "WEBHOOK_TOKEN = $webhook_token_fmt"
    info "Updated       = $updated_at"

    # Create ArgoCD Application — ArgoCD will run the Helm install/upgrade.
    # ignoreDifferences on the secret checksum annotation prevents OutOfSync/Degraded
    # every time secrets rotate (the annotation changes on each deploy).
    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${release}
  namespace: ${ARGOCD_NAMESPACE}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${git_url}
    targetRevision: ${git_revision}
    path: helm
    helm:
      releaseName: ${release}
      values: |
        podinfo:
          color: "${color}"
          message: |
            Updated:      ${updated_at}
            API_KEY:      ${api_key_fmt}
            DB_PASSWORD:  ${db_password_fmt}
            WEBHOOK_TOKEN:${webhook_token_fmt}
        secret:
          data:
            API_KEY: "${api_key}"
            DB_PASSWORD: "${db_password}"
            WEBHOOK_TOKEN: "${webhook_token}"
        ingress:
          enabled: true
          className: "${INGRESS_CLASS}"
          hosts:
            - host: "${hostname}"
              paths:
                - path: /
                  pathType: Prefix
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/template/metadata/annotations/checksum~1secret
EOF

    ok "$release Application created"
    echo
  done

  sep
  bold "Waiting for ArgoCD to sync and report Healthy..."
  echo
  local all_healthy=true
  for release in "${RELEASES[@]}"; do
    local health=""
    for _attempt in $(seq 1 20); do
      health="$(kubectl get application "$release" -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
      [[ "$health" == "Healthy" ]] && break
      sleep 6
    done
    if [[ "$health" == "Healthy" ]]; then
      ok "$release → $health"
    else
      warn "$release → ${health:-Unknown}  (check: argocd app get $release)"
      all_healthy=false
    fi
  done

  echo
  bold "URLs:"
  for release in "${RELEASES[@]}"; do
    echo "  http://$(release_host "$release")"
  done

  if [[ "$DOMAIN" != *.nip.io ]]; then
    sep
    cmd_dns
  fi
  echo
}

# ── dns (dnsmasq wildcard) ────────────────────────────────────────────────────
cmd_dns() {
  require_cmd kubectl

  local ip=""
  info "Detecting ingress IP..."
  for _attempt in 1 2 3 4 5; do
    ip="$(get_controller_ip)"
    [[ -n "$ip" ]] && break
    sleep 3
  done

  if [[ -z "$ip" ]]; then
    err "Could not detect ingress IP. Pass it manually:"
    err "  INGRESS_IP=1.2.3.4 ./scripts/demo.sh dns"
    ip="${INGRESS_IP:-}"
    [[ -z "$ip" ]] && exit 1
  fi

  ok "Ingress IP: $ip"

  local entry="address=/${DOMAIN}/${ip}  ${DNSMASQ_MARKER}"

  if grep -qF "$DNSMASQ_MARKER" "$DNSMASQ_CONF" 2>/dev/null; then
    # Update existing entry in-place
    sudo sed -i "/$DNSMASQ_MARKER/c\\${entry}" "$DNSMASQ_CONF"
    ok "Updated existing entry in $DNSMASQ_CONF"
  else
    echo "$entry" | sudo tee -a "$DNSMASQ_CONF" > /dev/null
    ok "Added to $DNSMASQ_CONF"
  fi

  # If port 53 is taken (systemd-resolved stub), disable the stub so dnsmasq
  # can bind. systemd-resolved keeps working — it just stops its own listener
  # and lets dnsmasq handle local resolution instead.
  if ss -tulpn 2>/dev/null | grep -q ':53 '; then
    warn "Port 53 in use — disabling systemd-resolved stub listener..."
    local resolved_conf="/etc/systemd/resolved.conf"
    if ! grep -q 'DNSStubListener=no' "$resolved_conf" 2>/dev/null; then
      sudo sed -i '/^#\?DNSStubListener=/d' "$resolved_conf"
      echo 'DNSStubListener=no' | sudo tee -a "$resolved_conf" > /dev/null
    fi
    sudo systemctl restart systemd-resolved
    ok "systemd-resolved stub disabled"
  fi

  info "Restarting dnsmasq..."
  sudo systemctl restart dnsmasq
  ok "dnsmasq restarted"
  echo

  # Verify
  if command -v dig &>/dev/null; then
    local resolved
    resolved="$(dig +short "kra-alpha.${DOMAIN}" @127.0.0.1 2>/dev/null || true)"
    if [[ "$resolved" == "$ip" ]]; then
      ok "DNS verified: kra-alpha.${DOMAIN} → $resolved"
    else
      warn "DNS check returned: '${resolved:-no answer}' (expected $ip)"
      warn "Check that your system uses 127.0.0.1 as nameserver."
    fi
  fi

  echo
  bold "URLs:"
  for release in "${RELEASES[@]}"; do
    echo "  http://$(release_host "$release")"
  done
  echo "  http://argocd.${DOMAIN}"
  echo
}

# ── hosts (for custom / .local domains) ──────────────────────────────────────
_print_hosts_block() {
  local ip="$1"
  local hostnames
  hostnames="$(for r in "${RELEASES[@]}"; do release_host "$r"; done | tr '\n' ' ')"
  # Include ArgoCD FQDN (argocd.<domain>) alongside the KRA releases
  printf '%s\n' "$HOSTS_MARKER_START"
  printf '%s  %sargocd.%s\n' "$ip" "$hostnames" "$DOMAIN"
  printf '%s\n' "$HOSTS_MARKER_END"
}

cmd_hosts() {
  require_cmd kubectl

  if [[ -z "$DOMAIN" ]]; then
    err "DOMAIN is not set. Run deploy first or set DOMAIN explicitly."
    exit 1
  fi

  if [[ "$DOMAIN" == *.nip.io ]]; then
    ok "Domain '$DOMAIN' uses nip.io — no /etc/hosts entry needed."
    for release in "${RELEASES[@]}"; do
      echo "  http://$(release_host "$release")"
    done
    return
  fi

  local ingress_ip=""
  info "Detecting ingress IP..."
  for _attempt in 1 2 3 4 5; do
    ingress_ip="$(get_ingress_ip)"
    [[ -n "$ingress_ip" ]] && break
    sleep 3
  done

  if [[ -z "$ingress_ip" ]]; then
    err "Could not detect ingress IP. Pass it manually:"
    err "  INGRESS_IP=1.2.3.4 DOMAIN=$DOMAIN ./scripts/demo.sh hosts"
    ingress_ip="${INGRESS_IP:-}"
    [[ -z "$ingress_ip" ]] && exit 1
  fi

  ok "Ingress IP: $ingress_ip"
  echo

  local block
  block="$(_print_hosts_block "$ingress_ip")"

  bold "/etc/hosts block:"
  echo
  echo "$block"
  echo

  if grep -qF "$HOSTS_MARKER_START" /etc/hosts 2>/dev/null; then
    warn "Entries already present in /etc/hosts. Remove with: ./scripts/demo.sh teardown"
    return
  fi

  bold "Apply to /etc/hosts? [y/N]"
  read -r answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    echo "$block" | sudo tee -a /etc/hosts > /dev/null
    ok "Written to /etc/hosts"
    echo
    bold "Open in browser:"
    for release in "${RELEASES[@]}"; do
      echo "  http://$(release_host "$release")"
    done
    echo "  http://argocd.${DOMAIN}"
  else
    info "Not applied. Paste the block above into /etc/hosts manually."
  fi
  echo
}

# ── teardown ──────────────────────────────────────────────────────────────────
cmd_teardown() {
  require_cmd kubectl

  bold "Removing ${#RELEASES[@]} ArgoCD Applications from namespace: $ARGOCD_NAMESPACE"
  sep
  for release in "${RELEASES[@]}"; do
    if kubectl get application "$release" -n "$ARGOCD_NAMESPACE" &>/dev/null 2>&1; then
      kubectl delete application "$release" -n "$ARGOCD_NAMESPACE"
      ok "deleted Application $release (finalizer will clean up resources)"
    else
      info "skipping $release (Application not found)"
    fi
  done
  echo

  if grep -qF "$DNSMASQ_MARKER" "$DNSMASQ_CONF" 2>/dev/null; then
    bold "Remove kra-demo entry from $DNSMASQ_CONF and restart dnsmasq? [y/N]"
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      sudo sed -i "/$DNSMASQ_MARKER/d" "$DNSMASQ_CONF"
      sudo systemctl restart dnsmasq
      ok "Removed from $DNSMASQ_CONF"
    else
      info "Left $DNSMASQ_CONF unchanged."
    fi
  fi

  if grep -qF "$HOSTS_MARKER_START" /etc/hosts 2>/dev/null; then
    bold "Remove kra-demo entries from /etc/hosts? [y/N]"
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      sudo sed -i "/$HOSTS_MARKER_START/,/$HOSTS_MARKER_END/d" /etc/hosts
      ok "Removed from /etc/hosts"
    else
      info "Left /etc/hosts unchanged."
    fi
  fi
  echo
  ok "Done."
}

# ── status ────────────────────────────────────────────────────────────────────
cmd_status() {
  require_cmd kubectl

  [[ -z "$DOMAIN" ]] && DOMAIN="<run deploy first>"

  bold "ArgoCD Application status — namespace: $ARGOCD_NAMESPACE"
  sep
  printf '\033[1m%-20s %-12s %-12s %-12s %s\033[0m\n' "RELEASE" "SYNC" "HEALTH" "POD" "URL"

  for release in "${RELEASES[@]}"; do
    if kubectl get application "$release" -n "$ARGOCD_NAMESPACE" &>/dev/null 2>&1; then
      local sync health pod_status
      sync="$(kubectl get application "$release" -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "?")"
      health="$(kubectl get application "$release" -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{.status.health.status}' 2>/dev/null || echo "?")"
      pod_status="$(kubectl get pods -n "$NAMESPACE" \
        -l "app.kubernetes.io/instance=$release" \
        --no-headers -o custom-columns='S:.status.phase' 2>/dev/null | head -1 || echo "?")"
      printf '%-20s %-12s %-12s %-12s http://%s\n' \
        "$release" "$sync" "$health" "$pod_status" "$(release_host "$release")"
    else
      printf '%-20s \033[33mnot found\033[0m\n' "$release"
    fi
  done
  echo
}

# ── bootstrap (install ingress-nginx) ────────────────────────────────────────
# Detects cluster type (kind / minikube / k3s / generic) and installs the
# matching ingress-nginx manifest, then waits for the controller to be ready.
_detect_cluster_type() {
  local node_name
  node_name="$(kubectl get nodes --no-headers -o custom-columns='N:.metadata.name' \
    2>/dev/null | head -1)"
  if [[ "$node_name" == *"kind"* ]]; then echo "kind"; return; fi
  if command -v minikube &>/dev/null && minikube status &>/dev/null 2>&1; then
    echo "minikube"; return
  fi
  # k3s ships traefik by default, but user may want nginx
  if kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null \
      | grep -qi "k3s"; then echo "k3s"; return; fi
  echo "generic"
}

cmd_bootstrap() {
  require_cmd kubectl

  bold "Bootstrap — install ingress-nginx"
  sep

  # Check if already installed
  if kubectl get ns ingress-nginx &>/dev/null 2>&1 && \
     kubectl get pods -n ingress-nginx -l 'app.kubernetes.io/name=ingress-nginx' \
       --no-headers 2>/dev/null | grep -q Running; then
    ok "ingress-nginx is already running"
    kubectl get pods -n ingress-nginx -l 'app.kubernetes.io/name=ingress-nginx' --no-headers
    echo
    return
  fi

  local cluster_type
  cluster_type="$(_detect_cluster_type)"
  info "Detected cluster type: $cluster_type"

  local manifest_url
  case "$cluster_type" in
    kind)
      manifest_url="https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml"
      ;;
    minikube)
      info "Enabling minikube ingress addon..."
      minikube addons enable ingress
      ok "ingress addon enabled — skipping manifest apply"
      echo
      bold "Run: ./scripts/demo.sh deploy"
      return
      ;;
    *)
      manifest_url="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml"
      ;;
  esac

  info "Applying: $manifest_url"
  kubectl apply -f "$manifest_url"
  echo

  info "Waiting for ingress-nginx controller to be ready (up to 3 minutes)..."
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s
  ok "ingress-nginx is ready"
  echo

  # For kind: the node IP is the ingress endpoint (hostPort binding)
  if [[ "$cluster_type" == "kind" ]]; then
    local node_ip
    node_ip="$(kubectl get nodes \
      -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
    ok "kind cluster — ingress endpoint: $node_ip (hostPort 80/443)"
    info "DNS wildcard already configured by 'demo.sh dns' will route here."
  fi

  echo
  bold "Next steps:"
  info "1. ./scripts/demo.sh deploy"
  info "2. ./scripts/demo.sh dns    (or hosts)"
  echo
}

# ── debug ─────────────────────────────────────────────────────────────────────
cmd_debug() {
  require_cmd kubectl
  local release="${RELEASES[0]}"
  local host
  host="$(release_host "$release")"
  local ip
  ip="$(get_controller_ip)"

  bold "=== 1. DNS"
  if host "$host" &>/dev/null; then
    local resolved
    resolved="$(host "$host" | awk '/has address/{print $NF}' | head -1)"
    ok "$host → $resolved"
    [[ "$resolved" != "$ip" ]] && warn "Expected $ip — mismatch!"
  else
    err "DNS does not resolve $host"
  fi
  echo

  bold "=== 2. Ingress controller pods"
  local ctrl_pods
  ctrl_pods="$(kubectl get pods -n ingress-nginx \
    -l 'app.kubernetes.io/name=ingress-nginx' --no-headers 2>/dev/null || true)"
  if [[ -n "$ctrl_pods" ]]; then
    kubectl get pods -n ingress-nginx -l 'app.kubernetes.io/name=ingress-nginx' -o wide
  else
    err "No ingress-nginx pods found"
    warn "Fix: ./scripts/demo.sh bootstrap"
  fi
  echo

  bold "=== 3. Ingress controller service"
  local ctrl_svc
  ctrl_svc="$(kubectl get svc -n ingress-nginx --no-headers 2>/dev/null || true)"
  if [[ -n "$ctrl_svc" ]]; then
    kubectl get svc -n ingress-nginx
  else
    err "No ingress-nginx service found"
    warn "Fix: ./scripts/demo.sh bootstrap"
  fi
  echo

  bold "=== 4. Ingress objects"
  kubectl get ingress -n "$NAMESPACE" -o wide
  # Warn if ADDRESS column is blank
  local no_addr
  no_addr="$(kubectl get ingress -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk '{print $5}' | grep -c '^$' || true)"
  [[ "$no_addr" -gt 0 ]] && warn "$no_addr ingress(es) have no ADDRESS — ingress controller may not be running"
  echo

  bold "=== 5. Ingress details (${release}-key-rotation-agent)"
  kubectl describe ingress "$(svc_name "$release")" -n "$NAMESPACE"
  echo

  bold "=== 6. HTTP — curl with explicit Host header"
  curl -sv --connect-timeout 5 -H "Host: $host" "http://${ip}" 2>&1 | \
    grep -E '(Connected|HTTP|< |curl:|refused|timed)' || true
  echo

  bold "=== 7. HTTP — curl the real URL"
  curl -sv --connect-timeout 5 "http://${host}" 2>&1 | \
    grep -E '(Connected|HTTP|< |curl:|refused|timed)' || true
  echo
}

# ── secrets ───────────────────────────────────────────────────────────────────
cmd_secrets() {
  require_cmd kubectl

  bold "Secrets — namespace: $NAMESPACE"
  sep

  local found=0
  for release in "${RELEASES[@]}"; do
    # Find the secret belonging to this release by instance label
    local secret_name
    secret_name="$(kubectl get secret -n "$NAMESPACE" \
      -l "app.kubernetes.io/instance=${release}" \
      --no-headers -o custom-columns='N:.metadata.name' 2>/dev/null | head -1)"

    if [[ -z "$secret_name" ]]; then
      printf '%-22s \033[33mnot found\033[0m\n' "$release"
      continue
    fi

    found=1

    # Pull full secret JSON once
    local secret_json
    secret_json="$(kubectl get secret "$secret_name" -n "$NAMESPACE" -o json 2>/dev/null)"

    # Last-update time: prefer lastAppliedConfigurationTimestamp from managedFields,
    # fall back to creationTimestamp
    local updated_at
    updated_at="$(printf '%s' "$secret_json" | \
      python3 -c "
import sys, json
s = json.load(sys.stdin)
# managedFields records operation times — pick the most recent 'Update'
times = [f.get('time','') for f in s.get('metadata',{}).get('managedFields',[]) if f.get('operation') == 'Update']
if times:
    print(max(times))
else:
    print(s['metadata'].get('creationTimestamp','unknown'))
" 2>/dev/null || echo "unknown")"

    printf '\n\033[1m%s\033[0m  (secret: %s)\n' "$release" "$secret_name"
    printf '  \033[36mUpdated:\033[0m %s\n' "$updated_at"

    # Decode and print each key
    local keys
    keys="$(printf '%s' "$secret_json" | \
      python3 -c "import sys,json; [print(k) for k in json.load(sys.stdin).get('data',{}).keys()]" \
      2>/dev/null)"

    if [[ -z "$keys" ]]; then
      printf '  \033[33m(no data keys)\033[0m\n'
      continue
    fi

    printf '  \033[1m%-20s  %s\033[0m\n' "KEY" "VALUE"
    while IFS= read -r key; do
      local val
      val="$(printf '%s' "$secret_json" | \
        python3 -c "
import sys, json, base64
d = json.load(sys.stdin).get('data', {})
print(base64.b64decode(d.get('${key}','')).decode('utf-8', errors='replace'))
" 2>/dev/null || echo "<decode error>")"
      printf '  %-20s  %s\n' "$key" "$val"
    done <<< "$keys"
  done

  [[ $found -eq 0 ]] && warn "No secrets found — run: ./scripts/demo.sh deploy"
  echo
}

# ── portforward (fallback) ────────────────────────────────────────────────────
cmd_portforward() {
  require_cmd kubectl

  local base_port=9000
  bold "Starting port-forwards (Ctrl-C to stop all)"
  sep

  local pids=()
  for i in "${!RELEASES[@]}"; do
    local release="${RELEASES[$i]}"
    local port=$(( base_port + i ))
    info "http://localhost:$port  →  $release"
    kubectl port-forward -n "$NAMESPACE" "svc/$(svc_name "$release")" "${port}:80" &>/dev/null &
    pids+=($!)
  done

  echo
  bold "Open in browser:"
  for i in "${!RELEASES[@]}"; do
    echo "  http://localhost:$(( base_port + i ))    (${RELEASES[$i]})"
  done
  echo
  info "Secrets visible on home page and at /env"

  trap 'kill "${pids[@]}" 2>/dev/null; echo; bold "Port-forwards stopped."' INT TERM
  wait
}

# ── entrypoint ────────────────────────────────────────────────────────────────
case "${1:-deploy}" in
  bootstrap)   cmd_bootstrap   ;;
  deploy)      cmd_deploy      ;;
  metallb)     cmd_metallb     ;;
  dns)         cmd_dns         ;;
  debug)       cmd_debug       ;;
  hosts)       cmd_hosts       ;;
  teardown)    cmd_teardown    ;;
  status)      cmd_status      ;;
  secrets)     cmd_secrets     ;;
  portforward) cmd_portforward ;;
  *)
    bold "Usage: $0 [bootstrap|deploy|metallb|dns|debug|hosts|teardown|status|secrets|portforward]"
    echo
    echo "  bootstrap    — install ingress-nginx (kind / minikube / cloud auto-detected)"
    echo "  deploy       — install 4 releases (auto-installs MetalLB if needed)"
    echo "  metallb      — install MetalLB and assign IP pool for kind clusters"
    echo "  dns          — add wildcard address=/${DOMAIN}/<ip> to $DNSMASQ_CONF"
    echo "  debug        — diagnose DNS, ingress controller, and HTTP connectivity"
    echo "  hosts        — write /etc/hosts entries (alternative to dns)"
    echo "  status       — show helm/pod status and URLs"
    echo "  secrets      — print secrets for each release with last-update time"
    echo "  teardown     — uninstall releases, clean dnsmasq + /etc/hosts"
    echo "  portforward  — fallback: forward pods to localhost:9000-9003"
    echo
    echo "Env vars: NAMESPACE  DOMAIN  INGRESS_CLASS  INGRESS_IP  DNSMASQ_CONF"
    exit 1
    ;;
esac
