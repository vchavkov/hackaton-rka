# Key Rotation Agent

A Helm-packaged demo of a Kubernetes key/secret rotation workflow, driven by
ArgoCD and a small set of helper scripts. Each release exposes a podinfo UI
that reflects the current secret value, so rotations are visible in real time.

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

## Demo workflow

The `scripts/demo.sh` driver wraps the full lifecycle.

```bash
# 0. Install ingress-nginx (only needed once per cluster)
./scripts/demo.sh bootstrap

# 1. Deploy — ingress enabled, hostnames set, secrets randomised
./scripts/demo.sh deploy

# 2. Hosts — detect ingress IP and write /etc/hosts (interactive y/N)
./scripts/demo.sh hosts

# 3. Show status + URLs
./scripts/demo.sh status

# 4. Tear everything down, including /etc/hosts entries (interactive y/N)
./scripts/demo.sh teardown
```

### What you get after `deploy` + `hosts`

ArgoCD UI:

- URL:      `http://argocd.demo.local`
- Username: `admin`
- Password: printed by `./scripts/demo.sh status`

KRA demo releases:

- `http://kra-alpha.demo.local`
- `http://kra-beta.demo.local`
- `http://kra-gamma.demo.local`
- `http://kra-delta.demo.local`

### How ingress hostnames work

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

### Override defaults

```bash
DOMAIN=demo.local INGRESS_CLASS=traefik NAMESPACE=demo \
  ./scripts/demo.sh deploy
```

### Why `bootstrap` is needed

Without an ingress controller the `Ingress` objects exist but nothing routes
to them — `ADDRESS` stays blank and port 80 is refused.

`bootstrap` does:

1. Detects the cluster type (e.g. `kind` from node IP / name) and applies the
   matching ingress-nginx manifest. The kind variant uses `hostPort` bindings
   so no LoadBalancer is required.
2. Waits for the controller pod to become Ready.
3. Prints the resulting endpoint.

Typical first-time sequence:

```bash
./scripts/demo.sh bootstrap   # install ingress-nginx
./scripts/demo.sh deploy      # ingresses now get an ADDRESS
./scripts/demo.sh hosts       # wildcard /etc/hosts entries
```

---

## Secret age monitoring & rotation

`scripts/secret-age.sh` reports the age of every secret in a namespace
(based on `creationTimestamp` and the latest `managedFields` update) and
optionally rotates the oldest one through ArgoCD.

### Inspect

```bash
# Check the demo namespace with the default 7-day threshold
./scripts/secret-age.sh

# Only show secrets that need rotation
./scripts/secret-age.sh --alert-only

# Different namespace, 30-day threshold
./scripts/secret-age.sh --namespace prod --threshold-days 30

# Machine-readable export for monitoring systems
./scripts/secret-age.sh --json --sort-by-age
```

### Rotate

`--rotate` finds the oldest secret labelled
`app.kubernetes.io/name=key-rotation-agent`, generates a new `DB_PASSWORD`,
and patches the matching ArgoCD `Application` so that selfHeal applies the
new value. Color and ingress settings are preserved.

```bash
# Rotate the oldest secret automatically
./scripts/secret-age.sh --rotate

# Use a non-default ArgoCD namespace
./scripts/secret-age.sh --rotate --argocd-namespace argo-system
```

### Options

| Flag | Default | Description |
| --- | --- | --- |
| `--namespace <ns>` | `demo` | Kubernetes namespace to inspect |
| `--argocd-namespace <ns>` | `argocd` | Namespace where ArgoCD `Application`s live |
| `--threshold-days <n>` | `7` | Age threshold for the alert column |
| `--alert-only` | off | Hide secrets within the threshold |
| `--json` | off | Emit JSON instead of a table |
| `--sort-by-age` | off | Sort oldest first |
| `--rotate` | off | Rotate the oldest matching secret via ArgoCD |
| `-h`, `--help` | — | Show built-in help |

Requires `kubectl` and `python3` on `PATH`.
