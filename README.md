# Key Rotation Agent

A Helm-packaged demo of a Kubernetes key/secret rotation workflow, driven by
ArgoCD and a small set of helper scripts. Each release exposes a podinfo UI
that reflects the current secret value, so rotations are visible in real time.

---

## Prerequisites

- A Kubernetes cluster (`kind`, `minikube`, `k3d` or any cloud cluster)
- `kubectl` configured against that cluster
- `helm` 3.x
- `python3` (`scripts/secret-age.py` requires Python 3.7+)
- `bash` 4+

---

## Quick install

```bash
# Default install (chart-managed secret)
helm install demo ./helm

# Point at an existing secret (e.g. from ESO / Vault)
helm install demo ./helm \
  --set secret.create=false \
  --set secret.existingSecret=my-vault-secret

# Expose via ingress
helm install demo ./helm \
  --set ingress.enabled=true \
  --set ingress.hosts[0].host=kra.demo.local

# Without ingress, port-forward to view the UI
kubectl port-forward svc/demo-key-rotation-agent 9898:80
# open http://localhost:9898
```

---

## Scripts

The `scripts/` directory contains three drivers:

| Script | Purpose |
| --- | --- |
| `scripts/demo.sh`       | End-to-end demo lifecycle: bootstrap cluster, deploy 4 releases, manage DNS / hosts, teardown |
| `scripts/argocd.sh`     | Install and manage ArgoCD itself (separate from app releases) |
| `scripts/secret-age.py` | Report secret age, rotate the oldest secret via ArgoCD, or clean up unused / stale secrets |

All three scripts accept a `-h` / `help` argument and print the usage shown
below.

### End-to-end demo flow

```bash
# 1. one-time cluster prep + deploy the 4 KRA releases via ArgoCD
./scripts/demo.sh bootstrap
./scripts/demo.sh deploy
./scripts/demo.sh hosts                     # wildcard /etc/hosts entries
./scripts/demo.sh status                    # URLs + ArgoCD admin password

# 2. rotate — picks the oldest of kra-{alpha,beta,gamma,delta}, generates a
# new DB_PASSWORD, patches the matching ArgoCD Application, and triggers a
# rolling restart so pods immediately pick up the new credentials.
./scripts/secret-age.py

# 3. clean up stale Helm release-history secrets that pile up over upgrades
./scripts/secret-age.py --cleanup

# 4. tear it all down
./scripts/demo.sh teardown
```

---

### `scripts/demo.sh`

```text
Usage: ./scripts/demo.sh [bootstrap|deploy|metallb|dns|debug|hosts|teardown|status|secrets|portforward]

  bootstrap    — install ingress-nginx (kind / minikube / cloud auto-detected)
  deploy       — install 4 releases (auto-installs MetalLB if needed)
  metallb      — install MetalLB and assign IP pool for kind clusters
  dns          — add wildcard address=/demo.local/<ip> to /etc/dnsmasq.conf
  debug        — diagnose DNS, ingress controller, and HTTP connectivity
  hosts        — write /etc/hosts entries (alternative to dns)
  status       — show helm/pod status and URLs
  secrets      — print secrets for each release with last-update time
  teardown     — uninstall releases, clean dnsmasq + /etc/hosts
  portforward  — fallback: forward pods to localhost:9000-9003

Env vars: NAMESPACE  DOMAIN  INGRESS_CLASS  INGRESS_IP  DNSMASQ_CONF
```

Typical first-time sequence:

```bash
./scripts/demo.sh bootstrap   # install ingress-nginx
./scripts/demo.sh deploy      # 4 KRA releases (alpha/beta/gamma/delta)
./scripts/demo.sh hosts       # /etc/hosts entries (or use `dns` for dnsmasq)
./scripts/demo.sh status      # URLs + ArgoCD admin password
./scripts/demo.sh teardown    # clean up everything
```

After `deploy` + `hosts` the following endpoints become reachable:

- `http://argocd.demo.local`   (admin / password printed by `status`)
- `http://kra-alpha.demo.local`
- `http://kra-beta.demo.local`
- `http://kra-gamma.demo.local`
- `http://kra-delta.demo.local`

Override defaults via env vars:

```bash
DOMAIN=demo.local INGRESS_CLASS=traefik NAMESPACE=demo \
  ./scripts/demo.sh deploy
```

#### How ingress hostnames work

Each release gets its own `Ingress` object:

- `kra-alpha.demo.local` → `kra-alpha-key-rotation-agent` svc
- `kra-beta.demo.local`  → `kra-beta-key-rotation-agent` svc
- ...

IP detection tries four strategies in order:

1. Ingress object IP
2. Ingress object hostname (AWS-style)
3. `ingress-nginx` controller LoadBalancer service
4. minikube / kind node IP

`/etc/hosts` is written with start/end markers so `teardown` can remove the
block cleanly with `sed`.

#### Why `bootstrap` is needed

Without an ingress controller the `Ingress` objects exist but nothing routes
to them — `ADDRESS` stays blank and port 80 is refused. `bootstrap` detects
the cluster type (kind / minikube / cloud), applies the matching
ingress-nginx manifest (kind variant uses `hostPort` so no LoadBalancer is
required), waits for the controller pod to become Ready, and prints the
resulting endpoint.

---

### `scripts/argocd.sh`

```text
Usage: ./scripts/argocd.sh [install|ingress|password|portforward|status|degraded|teardown|uninstall]

  install      — deploy ArgoCD, set password, and configure ingress
  ingress      — (re-)apply ingress for http://argocd.demo.local
  password     — (re-)set the admin password on an existing install
  portforward  — fallback: forward argocd-server to localhost:8080
  status       — show pod and service status
  degraded     — list applications with Degraded health status
  teardown     — remove ArgoCD and its namespace (no confirmation)
  uninstall    — same as teardown but asks for confirmation

Env vars: ARGOCD_NAMESPACE  ARGOCD_VERSION  ARGOCD_PASSWORD  ARGOCD_PORT
          DOMAIN (default: demo.local)  INGRESS_CLASS (default: nginx)
```

Examples:

```bash
# Fresh ArgoCD install with a custom admin password
ARGOCD_PASSWORD='S3cret!' ./scripts/argocd.sh install

# Reset password on an existing install
ARGOCD_PASSWORD='newpass' ./scripts/argocd.sh password

# Port-forward fallback when ingress isn't available
./scripts/argocd.sh portforward
# open https://localhost:8080

# Quickly see what is currently broken
./scripts/argocd.sh degraded
```

`scripts/demo.sh deploy` calls `argocd.sh install` internally, so you only
need this script directly when managing ArgoCD outside the demo flow (e.g.
rotating the admin password, debugging a Degraded app, or doing a clean
uninstall).

---

### `scripts/secret-age.py`

```text
usage: ./scripts/secret-age.py [-h] [--namespace NS] [--argocd-namespace NS]
                               [--threshold-days N] [--alert-only] [--json]
                               [--sort-by-age] [--rotate | --no-rotate]
                               [--cleanup] [--include-unreferenced] [--dry-run]

Default action:
  namespace == "demo"  → rotate the oldest secret via ArgoCD
  any other namespace  → check & report secret ages

Options:
  --namespace, -n NS        Kubernetes namespace (default: demo)
  --argocd-namespace NS     ArgoCD namespace (default: argocd)
  --threshold-days N        Age threshold in days for check mode (default: 7)
  --alert-only              Only show secrets exceeding the threshold
  --json                    Output check results as JSON
  --sort-by-age             Sort check results oldest first
  --rotate                  Force rotation of the oldest secret via ArgoCD
  --no-rotate               Force check-only (skip rotation even on 'demo')
  --cleanup                 Delete stale Helm release-history secrets
  --include-unreferenced    With --cleanup: also delete unreferenced secrets
  --dry-run                 With --cleanup: list candidates without deleting
  -h, --help                Show this help message
```

#### Default behavior

Running the script with no arguments rotates the oldest secret in the `demo`
namespace — that is the canonical demo flow:

```bash
# Default: rotate the oldest secret in 'demo' via ArgoCD
./scripts/secret-age.py
```

For any other namespace the default is check-only, so monitoring tooling and
ad-hoc inspections never accidentally trigger a rotation:

```bash
# Check 'prod' with a 30-day threshold (no rotation)
./scripts/secret-age.py --namespace prod --threshold-days 30
```

#### Inspect (opt out of rotation)

Pass `--no-rotate` (or any non-`demo` namespace) to get the report-only
behavior:

```bash
# Inspect 'demo' without rotating
./scripts/secret-age.py --no-rotate

# Only show secrets that need rotation
./scripts/secret-age.py --no-rotate --alert-only

# Machine-readable export for monitoring systems
./scripts/secret-age.py --no-rotate --json --sort-by-age
```

#### Rotate (opt in for non-`demo` namespaces)

`--rotate` finds the oldest secret labelled
`app.kubernetes.io/name=key-rotation-agent`, generates a new `DB_PASSWORD`,
and patches the matching ArgoCD `Application` so that selfHeal applies the
new value. Color and ingress settings are preserved.

```bash
# Force rotation in a non-default namespace
./scripts/secret-age.py --namespace staging --rotate

# Use a non-default ArgoCD namespace
./scripts/secret-age.py --rotate --argocd-namespace argo-system
```

The chart's `Deployment` carries a `checksum/secret` pod-template annotation
that hashes the rendered `Secret`. When the Secret content changes, the hash
changes, the pod template hash changes, and Kubernetes performs a rolling
restart so the pods pick up the new credentials. To make this work reliably
the rotate command does three things:

1. Patches `spec.source.helm.values` on the ArgoCD `Application` with the
   new `DB_PASSWORD`.
2. Clears `spec.ignoreDifferences` on the `Application` (an earlier version
   of `demo.sh` told ArgoCD to ignore the very `checksum/secret` annotation
   that's supposed to trigger the restart, which silently broke rotations).
3. Issues a `kubectl rollout restart` on the matching `Deployment` as a
   belt-and-suspenders trigger so the new pod starts immediately rather
   than waiting for the next ArgoCD sync.

Verifying a rotation actually rolled the pods:

```bash
kubectl -n demo get pods -l app.kubernetes.io/instance=kra-alpha
kubectl -n demo get deploy kra-alpha-key-rotation-agent \
  -o jsonpath='{.spec.template.metadata.annotations.checksum/secret}{"\n"}'
```

#### Cleanup unused secrets

`--cleanup` removes secrets that aren't doing anything useful. The default
mode is conservative — it only deletes **stale Helm release history** (the
`sh.helm.release.v1.<release>.v<N>` secrets where `N` is not the latest
revision per release). These are pure rollback metadata; Helm only ever reads
the latest revision, so deleting them is always safe.

```bash
# Preview what would be deleted
./scripts/secret-age.py --cleanup --dry-run

# Actually delete stale Helm history
./scripts/secret-age.py --cleanup
```

Add `--include-unreferenced` to also sweep secrets that no pod, controller
pod template, ServiceAccount or Ingress references. Several skip rules are
applied so the control plane isn't accidentally broken:

- Names starting with `argocd-` (ArgoCD reads several of these via the
  Kubernetes API rather than env/volumes, so the reference scan misses them).
- Secrets with an `app.kubernetes.io/part-of` or
  `app.kubernetes.io/managed-by` label.
- Secrets with a `meta.helm.sh/release-name` annotation.
- Secrets annotated `helm.sh/resource-policy: keep`.
- ServiceAccount tokens whose owning ServiceAccount still exists.

```bash
# Preview the broader sweep
./scripts/secret-age.py --cleanup --include-unreferenced --dry-run

# Apply it
./scripts/secret-age.py --cleanup --include-unreferenced
```

Requires `kubectl` and `python3` on `PATH`.
