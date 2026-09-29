#!/usr/bin/env bash
# Base preparation of the production node (OPS-01). Idempotent; run as root:
#   ssh root@<server> 'bash -s' < infra/server/bootstrap.sh
# SSH hardening is a separate step (harden-ssh.sh), run only after the deploy
# user has been confirmed to log in, so a mistake never locks the server out.
set -euo pipefail

DEPLOY_USER=deploy
NODE_NAME=outegro-prod

export DEBIAN_FRONTEND=noninteractive
hostnamectl set-hostname "$NODE_NAME"
timedatectl set-timezone UTC

apt-get update -q
apt-get -o Dpkg::Options::=--force-confold full-upgrade -yq
apt-get install -yq curl jq nftables fail2ban unattended-upgrades

# Security updates install themselves; reboots stay a manual decision.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades fail2ban

# Deploy user: key login, passwordless sudo for automation.
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG sudo "$DEPLOY_USER"
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-deploy
chmod 440 /etc/sudoers.d/90-deploy
visudo -cf /etc/sudoers.d/90-deploy
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /root/.ssh/authorized_keys "/home/$DEPLOY_USER/.ssh/authorized_keys"

echo "bootstrap done: $(hostname), $(lsb_release -ds), reboot needed: $([ -f /var/run/reboot-required ] && echo yes || echo no)"
