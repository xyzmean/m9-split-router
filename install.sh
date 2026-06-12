#!/usr/bin/env bash
# m9-split-router — turn a generic Linux box into a split-tunnel router for the
# M9 WireGuard network. All LAN internet traffic egresses through the VPN entry
# point (which then geo-splits ru/cn-direct vs blocked-via-m9-13); LAN-local
# traffic stays local. The LAN is routed TRANSPARENTLY (no NAT) so its subnet is
# reachable across the VPN mesh — register that subnet in the dashboard.
#
#   sudo ./install.sh -c router-m9-14.conf -l 192.168.50.0/24 -i eth1
#
#   -c  WireGuard config from the dashboard (router-<entrypoint>.conf)
#   -l  LAN subnet(s) behind this router (comma-separated CIDRs)
#   -i  LAN interface (the side facing your home devices)
#   -n  NAT mode: masquerade LAN onto the tunnel IP (hides the LAN; use only if
#       you do NOT need mesh-inbound to LAN devices). Default: transparent.
set -euo pipefail
CONF="" LAN="" LANIF="" NAT=0
while getopts "c:l:i:n" o; do case $o in
  c) CONF="$OPTARG";; l) LAN="$OPTARG";; i) LANIF="$OPTARG";; n) NAT=1;; esac; done
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
[[ -f "$CONF" && -n "$LAN" && -n "$LANIF" ]] || { echo "usage: $0 -c conf -l lan/cidr -i laniface [-n]"; exit 1; }

command -v wg-quick >/dev/null || { apt-get update -qq && apt-get install -y -qq wireguard-tools iptables; }

NAME="$(basename "$CONF" .conf)"; IF="m9-${NAME%%-*}"; [[ ${#IF} -le 15 ]] || IF="m9wg"
install -m600 "$CONF" "/etc/wireguard/${IF}.conf"

# forward + (optional) NAT, persisted as a tiny oneshot so it survives reboot
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-m9-router.conf

RULES="/usr/local/sbin/m9-router-rules.sh"
cat > "$RULES" <<RULESEOF
#!/bin/sh
IF="$IF"; LANIF="$LANIF"; LAN="$LAN"; NAT="$NAT"
iptables -C FORWARD -i \$LANIF -o \$IF -j ACCEPT 2>/dev/null || iptables -A FORWARD -i \$LANIF -o \$IF -j ACCEPT
iptables -C FORWARD -i \$IF -o \$LANIF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i \$IF -o \$LANIF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
if [ "\$NAT" = "1" ]; then
  for n in \$(echo \$LAN | tr ',' ' '); do
    iptables -t nat -C POSTROUTING -s \$n -o \$IF -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s \$n -o \$IF -j MASQUERADE
  done
fi
RULESEOF
chmod +x "$RULES"

cat > /etc/systemd/system/m9-router-rules.service <<UNITEOF
[Unit]
Description=m9 split-router forwarding rules
After=wg-quick@${IF}.service
Requires=wg-quick@${IF}.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$RULES
[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable --now "wg-quick@${IF}.service"
systemctl enable --now m9-router-rules.service

echo "== m9 split-router up: iface=$IF lan=$LAN via=$LANIF nat=$NAT =="
echo "   -> register LAN subnet(s) in the dashboard: client '$NAME' subnets = $LAN"
wg show "$IF" | grep -E "interface|endpoint|handshake" || true
