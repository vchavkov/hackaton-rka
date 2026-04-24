# Key Rotation Agent — Hackathon Demo

A Kubernetes demo that shows automated secret rotation via ArgoCD. Four Helm releases run the [podinfo](https://github.com/stefanprodan/podinfo) application, each backed by its own Kubernetes Secret. The rotation agent (`secret-age.py`) finds the oldest secret and patches the ArgoCD Application with a fresh password, which triggers a rolling pod restart via the `checksum/secret` annotation on the Deployment.

## Architecture

```
ArgoCD Application (x4)
  └── Helm chart (./helm)
        ├── Deployment       — podinfo container, mounts secret as volume + env vars
        ├── Service          — ClusterIP on port 80 → 9898
        ├── Ingress          — <release>.demo.local
        ├── Secret           — PASSWORD + UPDATED_AT (seeded by chart, rotated by agent)
        └── ServiceAccount
```

The `checksum/secret` pod annotation is computed at render time from the Secret manifest. When the Secret content changes, the annotation changes, Kubernetes sees a new pod template, and rolls the Deployment — no manual restart needed.

## Prerequisites

- `kubectl` connected to a cluster (kind recommended)
- `helm` v3
- `argocd` CLI (optional, for manual inspection)
- Python 3.7+ (for `secret-age.py` and `argocd-health.py`)
- `openssl` (used by `demo.sh deploy` to seed random passwords)

## Scripts

| Script | Purpose |
|---|---|
| `scripts/demo.sh`          | End-to-end demo lifecycle: bootstrap, deploy 4 releases, DNS, teardown |
| `scripts/argocd.sh`        | Install and manage the ArgoCD control plane |
| `scripts/argocd-health.sh` | Check health + sync status of ArgoCD Applications; exits 1 if any are unhealthy |
| `scripts/argocd-health.py` | Python implementation of the health check (called by the wrapper) |
| `scripts/secret-age.sh`    | Shell wrapper that finds `python3` and delegates to `secret-age.py` |
| `scripts/secret-age.py`    | Report secret age, rotate the oldest secret via ArgoCD, or clean up stale secrets |

## Quick Start

### 1. Bootstrap (first time only)

Install ingress-nginx and MetalLB (auto-detected for kind):

```bash
./scripts/demo.sh bootstrap
```

### 2. Deploy

Installs four ArgoCD Applications (`kra-alpha`, `kra-beta`, `kra-gamma`, `kra-delta`) in the `demo` namespace, each with a randomised initial password:

```bash
./scripts/demo.sh deploy
```

DNS is configured automatically via dnsmasq if available. To use `/etc/hosts` instead:

```bash
./scripts/demo.sh hosts
```

Override defaults with environment variables:

```bash
DOMAIN=demo.local INGRESS_CLASS=nginx NAMESPACE=demo ./scripts/demo.sh deploy
```

### 3. Open in browser

```
http://kra-alpha.demo.local
http://kra-beta.demo.local
http://kra-gamma.demo.local
http://kra-delta.demo.local
http://argocd.demo.local
```

Or use port-forwards (no ingress required):

```bash
./scripts/demo.sh portforward
# http://localhost:9000  (kra-alpha)
# http://localhost:9001  (kra-beta)
# http://localhost:9002  (kra-gamma)
# http://localhost:9003  (kra-delta)
```

## Secret Rotation

`scripts/secret-age.py` is the rotation agent. In the `demo` namespace it rotates by default; elsewhere it reports.

```bash
# Rotate the oldest secret in 'demo' (default behaviour)
./scripts/secret-age.sh

# Check ages without rotating
./scripts/secret-age.sh --no-rotate

# Only show secrets that need rotation (threshold: 7 days)
./scripts/secret-age.sh --no-rotate --alert-only

# Check a different namespace with a custom threshold
./scripts/secret-age.sh --namespace prod --threshold-days 30

# Machine-readable output for monitoring systems
./scripts/secret-age.sh --no-rotate --json --sort-by-age

# Force rotation in a non-default namespace
./scripts/secret-age.sh --namespace staging --rotate

# Preview stale Helm release-history secrets
./scripts/secret-age.sh --cleanup --dry-run

# Delete stale Helm release-history secrets
./scripts/secret-age.sh --cleanup

# Also sweep unreferenced secrets (skips argocd-* and managed secrets)
./scripts/secret-age.sh --cleanup --include-unreferenced --dry-run
```

Rotation flow:
1. Finds the secret with the oldest `kra/rotated-at` annotation (falls back to `managedFields` for secrets that have never been rotated), ensuring each release is rotated in round-robin order.
2. Patches the ArgoCD Application's Helm values with a new `PASSWORD` and `UPDATED_AT`.
3. Stamps `kra/rotated-at=<now>` directly on the Secret so future runs compare ages correctly (the Secret has `helm.sh/resource-policy: keep`, so Helm never re-applies it and `managedFields` stays frozen at deploy time).
4. ArgoCD syncs → Helm re-renders → `checksum/secret` annotation changes → Deployment rolls.
5. Issues an explicit `kubectl rollout restart` as a belt-and-suspenders fallback.

## secret-age.py Reference

`scripts/secret-age.py` is the rotation agent, invoked via the `scripts/secret-age.sh` wrapper.

| Flag | Default | Description |
|---|---|---|
| `--namespace`, `-n` | `demo` | Kubernetes namespace |
| `--argocd-namespace` | `argocd` | Namespace where ArgoCD Applications live |
| `--threshold-days` | `7` | Age threshold in days for check/alert mode |
| `--alert-only` | off | Only show secrets exceeding the threshold |
| `--json` | off | Output check results as JSON |
| `--sort-by-age` | off | Sort check results oldest first |
| `--rotate` | off | Force rotation (default for `demo` namespace) |
| `--no-rotate` | off | Force check-only (overrides `demo` default) |
| `--cleanup` | off | Delete stale Helm release-history secrets |
| `--include-unreferenced` | off | With `--cleanup`: also delete unreferenced secrets |
| `--dry-run` | off | With `--cleanup`: list candidates without deleting |

Environment variable overrides: `NAMESPACE`, `ARGOCD_NAMESPACE`.

## demo.sh Reference

```bash
./scripts/demo.sh <command>
```

| Command | Description |
|---|---|
| `bootstrap` | Install ingress-nginx (auto-detects kind / minikube / cloud) |
| `deploy` | Create/update 4 ArgoCD Applications with random secrets |
| `metallb` | Install MetalLB and configure an IP pool for kind clusters |
| `dns` | Add wildcard `address=/<domain>/<ip>` to dnsmasq |
| `hosts` | Write `/etc/hosts` entries (alternative to dns) |
| `status` | Show ArgoCD sync/health, pod status, and URLs |
| `secrets` | Print decoded secret values and last-update time for each release |
| `portforward` | Forward all four services to `localhost:9000-9003` |
| `debug` | Diagnose DNS, ingress controller, and HTTP connectivity |
| `teardown` | Delete ArgoCD Applications and clean dnsmasq / `/etc/hosts` |

Environment variable overrides:

| Variable | Default | Description |
|---|---|---|
| `NAMESPACE` | `demo` | Kubernetes namespace |
| `DOMAIN` | `demo.local` | Ingress hostname domain |
| `INGRESS_CLASS` | `nginx` | Ingress class name |
| `INGRESS_IP` | auto-detected | Override ingress IP for dns/hosts commands |
| `DNSMASQ_CONF` | `/etc/dnsmasq.conf` | Path to dnsmasq config |
| `ARGOCD_NAMESPACE` | `argocd` | ArgoCD namespace |

## Helm Chart Reference

Chart: `./helm` — `key-rotation-agent` v0.1.0, appVersion `6.7.0`

Key `values.yaml` options:

| Key | Default | Description |
|---|---|---|
| `image.repository` | `ghcr.io/stefanprodan/podinfo` | Container image |
| `image.tag` | chart appVersion | Image tag |
| `replicaCount` | `1` | Number of pod replicas |
| `secret.create` | `true` | Let the chart create the Secret |
| `secret.existingSecret` | `""` | Reference a pre-existing Secret instead |
| `secret.data` | `{PASSWORD: ...}` | Key/value pairs written into the Secret |
| `secretMount.volumePath` | `/etc/secrets` | Mount path for the secret volume |
| `secretMount.envVars` | `true` | Also expose each key as an env var |
| `ingress.enabled` | `false` | Enable the Ingress object |
| `ingress.className` | `""` | Ingress class |

To point at an existing secret (e.g. from External Secrets Operator or Vault):

```bash
helm install demo ./helm \
  --set secret.create=false \
  --set secret.existingSecret=my-vault-secret
```

## argocd-health.py Reference

`scripts/argocd-health.py` checks the health and sync status of ArgoCD Applications. Invoked via `scripts/argocd-health.sh`.

Exits `0` when all applications are `Healthy + Synced`, exits `1` otherwise — suitable for use in CI or as a readiness gate before running a rotation.

```bash
# Check all applications in the default ArgoCD namespace
./scripts/argocd-health.sh

# Check a single application
./scripts/argocd-health.sh --app kra-alpha

# Machine-readable output
./scripts/argocd-health.sh --json

# Watch continuously
watch -n 5 ./scripts/argocd-health.sh

# Use as a gate in CI
./scripts/argocd-health.sh || echo "cluster not ready"
```

| Flag | Default | Description |
|---|---|---|
| `--argocd-namespace`, `-n` | `argocd` | Namespace where ArgoCD Applications live |
| `--app NAME` | all apps | Check a single application by name |
| `--json` | off | Output results as JSON |

Environment variable override: `ARGOCD_NAMESPACE`.

## argocd.sh Reference

`scripts/argocd.sh` installs and manages the ArgoCD control plane itself (separate from the demo applications managed by `demo.sh`).

```bash
./scripts/argocd.sh <command>
```

| Command | Description |
|---|---|
| `install` | Deploy ArgoCD, set admin password, and configure ingress (default) |
| `ingress` | (Re-)apply the ingress for `http://argocd.<domain>` |
| `password` | (Re-)set the admin password on an existing install |
| `portforward` | Forward `argocd-server` to `localhost:8080` (fallback, no ingress needed) |
| `status` | Show ArgoCD pod and service status |
| `degraded` | List applications with `Degraded` health status |
| `unhealthy` | List all applications that are not `Healthy` (Degraded, Progressing, Missing, Suspended, Unknown) |
| `teardown` | Remove ArgoCD manifests and ingress (no confirmation prompt) |
| `uninstall` | Same as `teardown` but asks for confirmation |

Environment variable overrides:

| Variable | Default | Description |
|---|---|---|
| `ARGOCD_NAMESPACE` | `argocd` | Namespace where ArgoCD is installed |
| `ARGOCD_VERSION` | `stable` | ArgoCD manifest version tag |
| `ARGOCD_PASSWORD` | `admin123!` | Admin password to set on install |
| `ARGOCD_PORT` | `8080` | Local port used by `portforward` |
| `DOMAIN` | `demo.local` | Ingress hostname domain (matches `demo.sh`) |
| `INGRESS_CLASS` | `nginx` | Ingress class (matches `demo.sh`) |

## Teardown

```bash
./scripts/demo.sh teardown
```

Removes all four ArgoCD Applications (and the resources they manage via finalizers), then optionally cleans up dnsmasq and `/etc/hosts` entries.

To also remove the ArgoCD control plane itself:

```bash
./scripts/argocd.sh uninstall
```
