#!/usr/bin/env bash
# Single-node K3s (OPS-01), pinned version. Idempotent:
#   ssh deploy@<server> 'sudo bash -s' < infra/server/install-k3s.sh
# Stable channel on 29.09.2026; 1.37.0 had not reached it yet.
set -euo pipefail
K3S_VERSION="v1.36.4+k3s1"

# inotify: the default 128 instances per user runs out on a K3s node (K3s
# itself holds ~60). The kubelet then cannot follow container logs, and
# Alloy ships "failed to create fsnotify watcher: too many open files"
# instead of the pods' lines (seen 01.10.2026). Usual Kubernetes values.
cat > /etc/sysctl.d/90-inotify.conf <<'EOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF
sysctl --load /etc/sysctl.d/90-inotify.conf

install -d -m 755 /etc/rancher/k3s /var/lib/rancher/k3s/server/manifests
cat > /etc/rancher/k3s/config.yaml <<'EOF'
node-name: outegro-prod
write-kubeconfig-mode: "0600"
# Provider API keys live in Secrets: encrypt them in the datastore.
secrets-encryption: true
# Keep the OS and K3s itself alive when workloads press on 8 GB.
kubelet-arg:
  - "system-reserved=cpu=250m,memory=512Mi"
  - "kube-reserved=cpu=250m,memory=512Mi"
  - "eviction-hard=memory.available<200Mi,nodefs.available<10%"
EOF

# Traefik keeps the address of the connecting Cloudflare node (no SNAT).
cat > /var/lib/rancher/k3s/server/manifests/traefik-config.yaml <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    service:
      spec:
        externalTrafficPolicy: Local
EOF

current=$(command -v k3s >/dev/null && k3s --version | awk 'NR==1{print $3}' || true)
if [ "$current" != "$K3S_VERSION" ]; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
fi
until k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 3; done
k3s kubectl get nodes -o wide
