#!/bin/sh
# m9-split-router installer (OpenWrt 23+/24+/25, AmneziaWG).
#
# Turns a fresh OpenWrt router into a dashboard-managed split-tunnel gateway for
# the M9 network: blocked/foreign IPs ride the VPN, RU stays direct with zapret
# DPI bypass, and ALL policy (mode, lists, per-device, entry point) is then driven
# live from the dashboard by the on-router agent.
#
#   ./install.sh -c router-m9-14.conf -l 10.8.1.0/24 -i br-lan \
#                -u https://10.8.0.1:8443 -t <ROUTER_TOKEN> -k <ROUTER_PUBKEY>
#
#   -c  WireGuard/AmneziaWG config downloaded from the dashboard (router peer)
#   -l  LAN subnet behind this router (the dashboard advertises it on the mesh)
#   -i  LAN interface (default: br-lan)
#   -u  dashboard base URL (reachable over the mesh, e.g. https://10.8.0.1:8443)
#   -t  router token (dashboard: client → "Enable router management")
#   -k  router pubkey (the peer's PublicKey; ties the agent to the dashboard record)
#   -w  VPN interface name to create (default: wg0)
set -eu

CONF="" LAN="" LANIF="br-lan" DURL="" TOKEN="" PUBKEY="" VPNIF="wg0"
while getopts "c:l:i:u:t:k:w:" o; do case $o in
  c) CONF="$OPTARG";; l) LAN="$OPTARG";; i) LANIF="$OPTARG";; u) DURL="$OPTARG";;
  t) TOKEN="$OPTARG";; k) PUBKEY="$OPTARG";; w) VPNIF="$OPTARG";; esac; done

[ -f "$CONF" ] && [ -n "$LAN" ] && [ -n "$DURL" ] && [ -n "$TOKEN" ] || {
  echo "usage: $0 -c router-<entry>.conf -l LAN/CIDR -i LANIF -u DASHBOARD_URL -t TOKEN -k PUBKEY [-w wg0]" >&2
  exit 1; }

# Validate format to prevent shell injection via malicious args
echo "$LAN" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || { echo "LAN must be CIDR" >&2; exit 1; }
echo "$LANIF" | grep -qE '^[a-zA-Z0-9_-]+$' || { echo "LANIF must be alphanumeric" >&2; exit 1; }
echo "$VPNIF" | grep -qE '^[a-zA-Z0-9_-]+$' || { echo "VPNIF must be alphanumeric" >&2; exit 1; }
echo "$PUBKEY" | grep -qE '^[a-zA-Z0-9+/=]+$' || { echo "PUBKEY must be base64" >&2; exit 1; }
echo "$TOKEN" | grep -qE '^[a-zA-Z0-9_-]+$' || { echo "TOKEN must be alphanumeric" >&2; exit 1; }

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"
[ -d "$SRC/files" ] || { echo "run from the repo checkout (files/ missing)" >&2; exit 1; }

echo "== m9-split-router install: iface=$VPNIF lan=$LAN via=$LANIF dashboard=$DURL =="

# ---- 1. packages ----------------------------------------------------------
opkg update >/dev/null 2>&1 || true
for p in kmod-amneziawg amneziawg-tools luci-proto-amneziawg curl nftables-json; do
    opkg list-installed 2>/dev/null | grep -q "^$p " || opkg install "$p" >/dev/null 2>&1 || \
        echo "  warn: could not install $p (continuing)"
done
# zapret is optional; install if the feed has it, otherwise disable later.
ZAPRET_OK=1
opkg list-installed 2>/dev/null | grep -q '^zapret ' || \
    opkg install zapret luci-app-zapret >/dev/null 2>&1 || ZAPRET_OK=0

# ---- 2. parse the dashboard WG config -------------------------------------
val() { grep -i "^[[:space:]]*$1[[:space:]]*=" "$CONF" | head -1 | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//'; }
PRIV="$(val PrivateKey)"; ADDR="$(val Address)"; MTU="$(val MTU)"; DNS="$(val DNS)"
PUB="$(val PublicKey)"; PSK="$(val PresharedKey)"; EP="$(val Endpoint)"; AIP="$(val AllowedIPs)"
EPHOST="${EP%%:*}"; EPPORT="${EP##*:}"
WG_SRC_IP="$(echo "$ADDR" | sed 's#/.*##; s/,.*//')"
[ -n "$PRIV" ] && [ -n "$PUB" ] && [ -n "$EPHOST" ] || { echo "bad WG config: missing key/endpoint" >&2; exit 1; }
# AmneziaWG obfuscation params (present only for AWG entry points like m9-16)
JC="$(val Jc)"; JMIN="$(val Jmin)"; JMAX="$(val Jmax)"; S1="$(val S1)"; S2="$(val S2)"
H1="$(val H1)"; H2="$(val H2)"; H3="$(val H3)"; H4="$(val H4)"; I1="$(val I1)"

# ---- 3. AmneziaWG uci interface -------------------------------------------
uci -q delete "network.$VPNIF" || true
while uci -q delete "network.@amneziawg_${VPNIF}[0]" 2>/dev/null; do :; done
uci set "network.$VPNIF=interface"
uci set "network.$VPNIF.proto=amneziawg"
uci set "network.$VPNIF.private_key=$PRIV"
uci set "network.$VPNIF.mtu=${MTU:-1280}"
for a in $(echo "$ADDR" | tr ',' ' '); do uci add_list "network.$VPNIF.addresses=$a"; done
[ -n "$DNS" ] && for d in $(echo "$DNS" | tr ',' ' '); do uci add_list "network.$VPNIF.dns=$d"; done
for k in jc:"$JC" jmin:"$JMIN" jmax:"$JMAX" s1:"$S1" s2:"$S2" h1:"$H1" h2:"$H2" h3:"$H3" h4:"$H4" i1:"$I1"; do
    v="${k#*:}"; [ -n "$v" ] && uci set "network.$VPNIF.${k%%:*}=$v" || true
done
SEC="$(uci add network amneziawg_$VPNIF)"
uci set "network.$SEC.public_key=$PUB"
[ -n "$PSK" ] && uci set "network.$SEC.preshared_key=$PSK"
uci set "network.$SEC.endpoint_host=$EPHOST"
uci set "network.$SEC.endpoint_port=${EPPORT:-51820}"
uci set "network.$SEC.persistent_keepalive=15"
uci set "network.$SEC.route_allowed_ips=0"   # wg-split marks/routes, NOT a default route
for a in $(echo "${AIP:-0.0.0.0/0}" | tr ',' ' '); do uci add_list "network.$SEC.allowed_ips=$a"; done

# firewall zone for the tunnel (no masq: transparent so the LAN is mesh-reachable)
uci -q delete firewall.m9zone || true; uci -q delete firewall.m9fwd || true
uci set firewall.m9zone=zone
uci set firewall.m9zone.name='m9vpn'
uci set firewall.m9zone.input='REJECT'; uci set firewall.m9zone.output='ACCEPT'
uci set firewall.m9zone.forward='REJECT'; uci set firewall.m9zone.masq='0'
uci add_list firewall.m9zone.network="$VPNIF"
uci set firewall.m9fwd=forwarding
uci set firewall.m9fwd.src='lan'; uci set firewall.m9fwd.dest='m9vpn'
uci commit network; uci commit firewall

# ---- 4. lay down the wg-split stack ---------------------------------------
mkdir -p /etc/wg-split /usr/local/lib/wg-split /usr/local/sbin /etc/nftables.d
cp "$SRC/files/usr/local/lib/wg-split/common.sh" /usr/local/lib/wg-split/
cp "$SRC"/files/usr/local/sbin/* /usr/local/sbin/
chmod +x /usr/local/sbin/wg-split-* /usr/local/sbin/m9-rtr-agent
rm -f /etc/nftables.d/31-wg-split-policy.nft
cp "$SRC/files/etc/nftables.d/30-wg-split.nft" /etc/nftables.d/
cp "$SRC/files/etc/init.d/m9-rtr-agent" /etc/init.d/m9-rtr-agent
chmod +x /etc/init.d/m9-rtr-agent
echo "$(date +%Y%m%d)" > /etc/wg-split/VERSION

# substitute the static conf placeholders
sed -e "s#@@VPN_IFACE@@#$VPNIF#g" -e "s#@@WG_SRC_IP@@#$WG_SRC_IP#g" \
    -e "s#@@LAN_IFACE@@#$LANIF#g" -e "s#@@LAN_CIDR@@#$LAN#g" \
    -e "s#@@WG_ENDPOINTS@@#$EPHOST#g" -e "s#@@DASHBOARD_URL@@#$DURL#g" \
    -e "s#@@ROUTER_TOKEN@@#$TOKEN#g" -e "s#@@ROUTER_PUBKEY@@#$PUBKEY#g" \
    "$SRC/files/etc/wg-split/wg-split.conf.tmpl" > /etc/wg-split/wg-split.conf
[ "$ZAPRET_OK" = 1 ] || sed -i 's/^ZAPRET_ENABLED=.*/ZAPRET_ENABLED="0"/' /etc/wg-split/wg-split.conf

# seed a default policy so the box works before the first dashboard sync
ZJSON=$([ "$ZAPRET_OK" = 1 ] && echo true || echo false)
cat > /etc/wg-split/policy.json <<JSON
{"ok":true,"rev":1,"policy":{"rev":1,"mode":"blocklist","entry":"","ipsum":true,"ru_direct":true,"zapret":$ZJSON,"killswitch":false,"dns_via_vpn":false,"vpn_cidrs":[],"vpn_domains":[],"direct_cidrs":[],"direct_domains":[],"devices":[]},"endpoints":{}}
JSON

# ---- 5. bring up + populate lists -----------------------------------------
ifup "$VPNIF" >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true
/etc/init.d/firewall reload >/dev/null 2>&1 || true
echo "  fetching ipsum + ru lists (first run)…"
/usr/local/sbin/wg-split-update-ipsum >/dev/null 2>&1 || echo "  warn: ipsum fetch failed (watchdog will retry)"
/usr/local/sbin/wg-split-update-ru    >/dev/null 2>&1 || true
[ "$ZAPRET_OK" = 1 ] && /usr/local/sbin/wg-split-sync-nozapret >/dev/null 2>&1 || true

# generate the policy layer + install routes
/usr/local/sbin/wg-split-apply >/dev/null 2>&1 || true

# ---- 6. cron + agent ------------------------------------------------------
CRON=/etc/crontabs/root; touch "$CRON"
grep -q 'wg-split-watchdog'     "$CRON" || echo '*/3 * * * * /usr/local/sbin/wg-split-watchdog >/dev/null 2>&1'    >> "$CRON"
grep -q 'wg-split-update-ipsum' "$CRON" || echo '30 4 * * * /usr/local/sbin/wg-split-update-ipsum >/dev/null 2>&1' >> "$CRON"
grep -q 'wg-split-update-ru'    "$CRON" || echo '45 4 * * * /usr/local/sbin/wg-split-update-ru >/dev/null 2>&1'    >> "$CRON"
/etc/init.d/cron enable >/dev/null 2>&1 || true; /etc/init.d/cron restart >/dev/null 2>&1 || true

/etc/init.d/m9-rtr-agent enable >/dev/null 2>&1 || true
/etc/init.d/m9-rtr-agent restart >/dev/null 2>&1 || /etc/init.d/m9-rtr-agent start >/dev/null 2>&1 || true

echo "== done. peer=$WG_SRC_IP lan=$LAN entry=$EPHOST zapret=$ZAPRET_OK =="
echo "   register in dashboard: client subnets = $LAN ; router management = on"
sleep 2; wg show "$VPNIF" 2>/dev/null | grep -E 'interface|endpoint|handshake' || \
    awg show "$VPNIF" 2>/dev/null | grep -E 'interface|endpoint|handshake' || true
echo "   agent log: logread -e m9-rtr-agent ; split status: wg-split-status"
