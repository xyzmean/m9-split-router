#!/bin/sh
# m9-split-router for OpenWrt — adds a WireGuard interface that tunnels LAN
# internet traffic through the M9 VPN, transparently (LAN reachable on the mesh).
# Parses a dashboard router-<entry>.conf and wires up uci network + firewall.
#
#   ./openwrt-setup.sh router-m9-14.conf 192.168.1.0/24
#
# arg1: dashboard WG config   arg2: this router's LAN subnet (for the dashboard)
set -e
CONF="$1"; LAN="${2:-}"
[ -f "$CONF" ] || { echo "usage: $0 router-<entry>.conf [lan/cidr]"; exit 1; }
IF="m9vpn"

val() { grep -i "^$1" "$CONF" | head -1 | sed 's/^[^=]*=[[:space:]]*//'; }
PRIV="$(val PrivateKey)"; ADDR="$(val Address)"; DNS="$(val DNS)"; MTU="$(val MTU)"
PUB="$(val PublicKey)"; PSK="$(val PresharedKey)"; EP="$(val Endpoint)"; AIP="$(val AllowedIPs)"
EPHOST="${EP%%:*}"; EPPORT="${EP##*:}"

opkg list-installed | grep -q wireguard-tools || { opkg update; opkg install wireguard-tools kmod-wireguard; }

uci -q delete network.$IF; uci -q delete network.${IF}peer
uci set network.$IF=interface
uci set network.$IF.proto='wireguard'
uci set network.$IF.private_key="$PRIV"
uci set network.$IF.mtu="${MTU:-1380}"
for a in $(echo "$ADDR" | tr ',' ' '); do uci add_list network.$IF.addresses="$a"; done

uci set network.${IF}peer=wireguard_$IF
uci set network.${IF}peer.public_key="$PUB"
[ -n "$PSK" ] && uci set network.${IF}peer.preshared_key="$PSK"
uci set network.${IF}peer.endpoint_host="$EPHOST"
uci set network.${IF}peer.endpoint_port="$EPPORT"
uci set network.${IF}peer.persistent_keepalive='15'
uci set network.${IF}peer.route_allowed_ips='1'
for a in $(echo "$AIP" | tr ',' ' '); do uci add_list network.${IF}peer.allowed_ips="$a"; done

# firewall: put the tunnel in a zone that masquerades nothing (transparent) and
# allow LAN -> VPN forwarding so home devices egress through it.
uci -q delete firewall.m9zone; uci -q delete firewall.m9fwd
uci set firewall.m9zone=zone
uci set firewall.m9zone.name='m9vpn'
uci set firewall.m9zone.input='REJECT'
uci set firewall.m9zone.output='ACCEPT'
uci set firewall.m9zone.forward='REJECT'
uci set firewall.m9zone.masq='0'
uci add_list firewall.m9zone.network="$IF"
uci set firewall.m9fwd=forwarding
uci set firewall.m9fwd.src='lan'
uci set firewall.m9fwd.dest='m9vpn'

uci commit network; uci commit firewall
/etc/init.d/network reload; /etc/init.d/firewall reload
sleep 2
echo "== m9-split-router (OpenWrt) up on $IF =="
[ -n "$LAN" ] && echo "   -> register LAN subnet in dashboard: subnets = $LAN"
wg show $IF 2>/dev/null | grep -E "interface|endpoint|handshake" || logread -e wireguard | tail -3
