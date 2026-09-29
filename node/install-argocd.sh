#!/usr/bin/env bash
# Argo CD bootstrap (once per cluster):
#   ssh outegro-prod 'sudo bash -s' < node/install-argocd.sh
# Installs Argo CD, creates the read-only deploy key for this repo and prints
# its public half (add it to github.com/outegro-dev/gitops → Deploy keys),
# then applies bootstrap/root.yaml separately:
#   ssh outegro-prod sudo k3s kubectl apply -f - < bootstrap/root.yaml
# From then on Argo CD manages itself (platform/argocd) and everything else.
set -euo pipefail
ARGOCD_VERSION=v3.5.3
k() { k3s kubectl "$@"; }

k create namespace argocd --dry-run=client -o yaml | k apply -f - >/dev/null
k apply --server-side --force-conflicts -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
# Same trimming as platform/argocd, so the first sync changes nothing.
for d in argocd-dex-server argocd-applicationset-controller argocd-notifications-controller; do
  k -n argocd scale deploy "$d" --replicas=0 >/dev/null
done
for d in argocd-server argocd-repo-server argocd-redis; do
  k -n argocd rollout status deploy "$d" --timeout=300s >/dev/null
done
k -n argocd rollout status statefulset argocd-application-controller --timeout=300s >/dev/null

# Read-only deploy key: the private half stays in the cluster only.
if ! k -n argocd get secret repo-gitops >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  ssh-keygen -q -t ed25519 -N "" -C "argocd@outegro-prod" -f "$tmp/key"
  k -n argocd create secret generic repo-gitops \
    --from-literal=type=git \
    --from-literal=url=git@github.com:outegro-dev/gitops.git \
    --from-file=sshPrivateKey="$tmp/key" >/dev/null
  k -n argocd label secret repo-gitops argocd.argoproj.io/secret-type=repository >/dev/null
  echo "deploy key (read-only) for outegro-dev/gitops:"
  cat "$tmp/key.pub"
  rm -rf "$tmp"
else
  echo "repo-gitops exists; deploy key unchanged"
fi
