#!/usr/bin/env bash
# Host firewall (OPS-01), installed once:
#   ssh deploy@<server> 'sudo bash -s' < infra/server/firewall.sh
#
# Lives in its own nftables table and never flushes the ruleset, so it
# coexists with the rules K3s manages. The web ports are filtered in
# prerouting, before K3s rewrites the destination to a pod; input rules alone
# would never see that traffic. Cloudflare ranges refresh weekly.
set -euo pipefail

install -d -m 755 /etc/outegro

cat > /usr/local/sbin/outegro-firewall <<'SCRIPT'
#!/usr/bin/env bash
# Regenerates /etc/outegro/firewall.nft from Cloudflare's published ranges and loads it.
set -euo pipefail
iface=$(ip -4 route show default | awk '{print $5; exit}')
v4=$(curl -fsS --max-time 20 https://www.cloudflare.com/ips-v4)
v6=$(curl -fsS --max-time 20 https://www.cloudflare.com/ips-v6)
# An empty or garbled list would take the sites offline: refuse to apply it.
[ "$(grep -cE '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' <<<"$v4")" -ge 10 ] || { echo "bad IPv4 list" >&2; exit 1; }
[ "$(grep -cE '^[0-9a-f:]+/[0-9]{1,3}$' <<<"$v6")" -ge 5 ] || { echo "bad IPv6 list" >&2; exit 1; }
join() { paste -sd, -; }
cat > /etc/outegro/firewall.nft.new <<EOF
table inet outegro_guard
delete table inet outegro_guard
table inet outegro_guard {
  set cloudflare_v4 { type ipv4_addr; flags interval; elements = { $(join <<<"$v4") } }
  set cloudflare_v6 { type ipv6_addr; flags interval; elements = { $(join <<<"$v6") } }

  # Web ports only from Cloudflare, before any DNAT to pods.
  chain prerouting {
    type filter hook prerouting priority raw; policy accept;
    iifname "$iface" tcp dport { 80, 443 } ip saddr != @cloudflare_v4 drop
    iifname "$iface" tcp dport { 80, 443 } ip6 saddr != @cloudflare_v6 drop
  }

  # Host services from outside: SSH, ICMP and DHCP replies only.
  # The K3s API, kubelet and everything else stay reachable from pods alone.
  chain input {
    type filter hook input priority filter - 10; policy accept;
    iifname "lo" accept
    iifname != "$iface" accept
    ct state established,related accept
    tcp dport 22 accept
    udp dport { 68, 546 } accept
    meta l4proto { icmp, ipv6-icmp } accept
    drop
  }
}
EOF
nft -c -f /etc/outegro/firewall.nft.new
mv /etc/outegro/firewall.nft.new /etc/outegro/firewall.nft
nft -f /etc/outegro/firewall.nft
echo "firewall loaded on $iface: $(wc -l <<<"$v4") IPv4 and $(wc -l <<<"$v6") IPv6 Cloudflare ranges"
SCRIPT
chmod 755 /usr/local/sbin/outegro-firewall

# At boot: load the last good ruleset before the network and K3s come up.
cat > /etc/systemd/system/outegro-firewall.service <<'EOF'
[Unit]
Description=outegro host firewall
DefaultDependencies=no
Before=network-pre.target k3s.service
Wants=network-pre.target
ConditionPathExists=/etc/outegro/firewall.nft

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/outegro/firewall.nft

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/outegro-firewall-refresh.service <<'EOF'
[Unit]
Description=Refresh Cloudflare ranges in the outegro firewall
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/outegro-firewall
EOF

cat > /etc/systemd/system/outegro-firewall-refresh.timer <<'EOF'
[Unit]
Description=Weekly Cloudflare range refresh

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

/usr/local/sbin/outegro-firewall
systemctl daemon-reload
systemctl enable outegro-firewall.service outegro-firewall-refresh.timer
systemctl start outegro-firewall-refresh.timer
nft list table inet outegro_guard | grep -E 'chain|drop|accept' | sed 's/^\s*//'
