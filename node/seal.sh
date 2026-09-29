#!/usr/bin/env bash
# Seals Secrets that already exist in the cluster into SealedSecret YAML for
# this repo. Plain values never leave the server; the output is encrypted
# with the controller key and safe to commit.
#   ssh outegro-prod 'sudo bash -s -- outegro/lava' < node/seal.sh > apps/production/secrets/lava.yaml
# To change a provider key: node/secrets.sh on the server, then seal again.
set -euo pipefail
KUBESEAL_VERSION=0.40.0
k() { k3s kubectl "$@"; }

if ! command -v kubeseal >/dev/null || ! kubeseal --version 2>/dev/null | grep -q "$KUBESEAL_VERSION"; then
  tmp=$(mktemp -d)
  base="https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}"
  curl -fsSL -o "$tmp/kubeseal.tar.gz" "$base/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
  curl -fsSL -o "$tmp/checksums.txt" "$base/sealed-secrets_${KUBESEAL_VERSION}_checksums.txt"
  expected=$(grep "kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" "$tmp/checksums.txt" | awk '{print $1}')
  echo "$expected  $tmp/kubeseal.tar.gz" | sha256sum -c --quiet - >&2
  tar -xzf "$tmp/kubeseal.tar.gz" -C "$tmp" kubeseal
  install -m 755 "$tmp/kubeseal" /usr/local/bin/kubeseal
  rm -rf "$tmp"
fi

for ref in "$@"; do
  ns=${ref%%/*}
  name=${ref#*/}
  # Lets the controller take over the Secret that was created by hand.
  k -n "$ns" annotate secret "$name" sealedsecrets.bitnami.com/managed=true --overwrite >/dev/null
  echo "---"
  k -n "$ns" get secret "$name" -o json \
    | jq 'del(.metadata.annotations, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields, .metadata.ownerReferences)' \
    | KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller --format yaml
done
