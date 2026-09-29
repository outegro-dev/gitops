#!/usr/bin/env bash
# SSH lockdown (OPS-01): only the deploy user, keys only, few attempts.
# Run after `ssh deploy@<server>` has been confirmed to work:
#   ssh deploy@<server> 'sudo bash -s' < infra/server/harden-ssh.sh
set -euo pipefail

# The first value sshd reads wins, and drop-ins are read in name order, so
# 10- takes precedence over provider files such as 50-cloud-init.conf.
cat > /etc/ssh/sshd_config.d/10-outegro.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
AllowUsers deploy
X11Forwarding no
EOF
sshd -t
systemctl restart ssh
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|allowusers|maxauthtries) '
