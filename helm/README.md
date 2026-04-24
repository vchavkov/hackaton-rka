# Quick install

# with default (chart-managed) secret
helm install demo ./helm

# point at an existing secret (e.g. from ESO / Vault)
helm install demo ./helm \
--set secret.create=false \
--set secret.existingSecret=my-vault-secret

# expose via ingress
helm install demo ./helm \
--set ingress.enabled=true \
--set ingress.hosts[0].host=kra.demo.local

# After install, port-forward to see the secrets reflected in the UI:

kubectl port-forward svc/demo-key-rotation-agent 9898:80
# open http://localhost:9898


 Workflow

# 1. deploy — ingress enabled, hostnames set, secrets randomised
./scripts/demo.sh deploy

# 2. hosts — detect ingress IP, write /etc/hosts (interactive y/N)
./scripts/demo.sh hosts

# 3. open browser — no port-forward needed
#    http://kra-alpha.demo.local
#    http://kra-beta.demo.local
#    http://kra-gamma.demo.local
#    http://kra-delta.demo.local

# 4. show status + URLs in one line
./scripts/demo.sh status

# 5. clean up everything incl. /etc/hosts (interactive y/N)
./scripts/demo.sh teardown

How ingress hostnames work

Each release gets its own Ingress object:
- kra-alpha.demo.local → kra-alpha-key-rotation-agent svc
- kra-beta.demo.local → kra-beta-key-rotation-agent svc
- …

IP detection tries 4 strategies in order: ingress object IP → ingress object hostname (AWS) → ingress-nginx controller LB service → minikube/kind node IP.

/etc/hosts is written with start/end markers so teardown can remove it cleanly with sed.

Override defaults

DOMAIN=demo.local INGRESS_CLASS=traefik NAMESPACE=demo ./scripts/demo.sh deploy


 Run this now to fix the cluster:

./scripts/demo.sh bootstrap

Root cause: No ingress controller was installed. The ingresses exist but nothing watches them to configure routing — that's why ADDRESS is blank and port 80 is refused.

What bootstrap does:
1. Detects the cluster type — your node IP (172.18.0.2) and name pattern points to kind, so it applies the kind-specific manifest which uses hostPort bindings (no LoadBalancer needed)
2. Waits for the controller pod to reach Ready
3. Prints the endpoint

Full workflow after bootstrap:
./scripts/demo.sh bootstrap   # installs ingress-nginx
./scripts/demo.sh deploy      # re-deploy (ingresses will now get an ADDRESS)
./scripts/demo.sh dns         # wildcard DNS → 172.18.0.2

Usage examples:
  # Check demo namespace with default 7-day threshold
  ./scripts/secret-age.sh

  # Only show secrets needing rotation
  ./scripts/secret-age.sh --alert-only

  # Check another namespace, 30-day threshold
  ./scripts/secret-age.sh --namespace prod --threshold-days 30

  # Export for monitoring systems
  ./scripts/secret-age.sh --json --sort-by-age



