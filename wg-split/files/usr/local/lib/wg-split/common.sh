# wg-split common helpers. Sourced (not exec'd) by every wg-split-* script.
# Config now lives in UCI (/etc/config/wg-split) — loaded here into the same
# variable names the scripts have always used. Requires: busybox ash, nft, ip,
# logger, and OpenWrt's /lib/functions.sh (uci config helpers).

# shellcheck disable=SC1091
. /lib/functions.sh
config_load wg-split

# ---- user-tunable knobs (UCI 'global' section) -----------------------------
config_get        MODE            global mode            blocklist
config_get        INTERVAL        global interval        180
config_get_bool   KILLSWITCH      global killswitch      0
config_get        LAN_IFACE       global lan_iface       br-lan
config_get        LAN_CIDR        global lan_cidr        ''
config_get        HEALTH_TARGETS  global health_target   '1.1.1.1 8.8.8.8'
config_get        HEALTH_CURL_URL global health_url       'https://1.1.1.1/cdn-cgi/trace'
config_get_bool   ZAPRET_ENABLED  global zapret_enabled  1
config_get_bool   IPSUM_ENABLED   global ipsum_enabled   1
config_get        IPSUM_URL       global ipsum_url       ''
config_get_bool   RU_ENABLED      global ru_enabled      1
config_get        RU_URL          global ru_url          ''
config_get        VPN_DOMAINS_URL    global vpn_domains_url    ''
config_get        IGNORE_DOMAINS_URL global ignore_domains_url ''
config_get        VPN_CIDRS       global vpn_cidr        ''
config_get        DIRECT_CIDRS    global direct_cidr     ''
config_get        VPN_DOMAINS     global vpn_domain      ''
config_get        DIRECT_DOMAINS  global direct_domain   ''

# ---- static constants (not user-tunable; were operator-owned, effectively fixed) ----
WG_TABLE="200"
WG_MARK="0x40000";        WG_MARK_MASK="0x40000";   WG_RULE_PRIO="999"
ANTI_LOOP_MARK="0x10000"; ANTI_LOOP_MASK="0x10000"; ANTI_LOOP_PRIO="1000"
DOH_IPS="8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 149.112.112.112"

VPN_SET="wg_split_vpn_v4"
DIRECT_SET="wg_split_direct_v4"
POLICY_NFT_FILE="/etc/nftables.d/30-wg-split.nft"
DNSMASQ_NFTSET_FILE="/tmp/dnsmasq.d/wg-split-domains.conf"

IPSUM_FILE="/etc/wg-split/ipsum.lst"
IPSUM_NFT_FILE="/etc/wg-split/ipsum-set.nft"
IPSUM_SET="wg_split_ipsum_v4"; IPSUM_TABLE="inet fw4"
IPSUM_MIN_COUNT="5000"; IPSUM_FALLBACK_SKIP="1"

RU_FILE="/etc/wg-split/ru_subnets.lst"
RU_NFT_FILE="/etc/wg-split/ru-set.nft"
RU_SET="wg_split_ru_subnets_v4"; RU_TABLE="inet fw4"; RU_MIN_COUNT="5000"

DOMAINS_VPN_FILE="/etc/wg-split/vpn-domains.lst"
DOMAINS_IGNORE_FILE="/etc/wg-split/ignore-domains.lst"

ZAPRET_INIT="/etc/init.d/zapret"
ZAPRET_NOZAPRET_SET="nozapret"; ZAPRET_NOZAPRET_TABLE="inet zapret"; ZAPRET_NOZAPRET_MIN="1000"
ZAPRET_PRIVATES="10.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 100.64.0.0/10 224.0.0.0/4 240.0.0.0/4"

# health probing (ping THROUGH the tunnel iface)
HEALTH_PING_COUNT="1"; HEALTH_PING_TIMEOUT="2"; HEALTH_CURL_TIMEOUT="5"
# handshake wait when probing a freshly-upped candidate
HS_WAIT="10"

LOG_TAG="wg-split"
STATE_FILE="/var/run/wg-split-state"
FAIL_COUNTER_FILE="/var/run/wg-split-failcount"

log()  { logger -t "$LOG_TAG" "$*"; }
die()  { log "ERROR: $*"; echo "ERROR: $*" >&2; exit 1; }
warn() { log "WARN: $*"; }

# ---- failover endpoints (UCI 'endpoint' sections, lowest priority wins) -----
# emit "priority<TAB>iface" per section; callers sort.
_collect_endpoint() {
    local iface prio
    config_get iface "$1" iface ''
    config_get prio  "$1" priority 99
    [ -n "$iface" ] && printf '%s\t%s\n' "$prio" "$iface"
}
# space-separated iface list, ordered by priority (best first).
endpoints_by_priority() {
    config_foreach _collect_endpoint endpoint | sort -n -k1,1 | cut -f2 | tr '\n' ' '
}
# the single highest-priority iface (used as default/active fallback).
top_endpoint() { endpoints_by_priority | awk '{print $1}'; }

# ---- active-path state -----------------------------------------------------
# State file holds the live path: "vpn:<iface>" | "zapret" | "wan".
read_state()  { cat "$STATE_FILE" 2>/dev/null || true; }
write_state() { printf '%s\n' "$1" > "$STATE_FILE"; }
# iface currently carrying VPN traffic (from state), else top-priority endpoint.
# A saved iface that is no longer a configured endpoint (removed/renamed in UCI)
# is ignored so we never probe/route a stale device.
active_iface() {
    _s="$(read_state)"
    case "$_s" in
        vpn:*)
            _cur="${_s#vpn:}"
            case " $(endpoints_by_priority) " in
                *" $_cur "*) echo "$_cur"; return ;;
            esac
            ;;
    esac
    top_endpoint
}
# VPN_IFACE keeps backward-compat for scripts that reference a single iface
# (apply/status). It is the live active iface, or the top-priority one at boot.
VPN_IFACE="$(active_iface)"
[ -n "$VPN_IFACE" ] || VPN_IFACE="$(top_endpoint)"

# source IP of an iface (for route `src`, DoH pins). Empty if down/none.
iface_src_ip() {
    ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

# ---- nft / routing helpers (unchanged) -------------------------------------
set_count() {
    _cnt="$(nft list set "$1" "$2" 2>/dev/null \
        | tr ',' '\n' \
        | grep -cE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        || true)"
    echo "${_cnt:-0}"
}

has_rule() { ip -4 rule show | grep -q "$1"; }

delete_rule_prio() {
    while ip -4 rule del priority "$1" >/dev/null 2>&1; do :; done
}

# Ensure ip rule at PRIO matches PATTERN; recreates if missing/wrong.
ensure_rule() {
    _prio="$1"; _pattern="$2"; shift 2
    if ! has_rule "${_prio}:.*${_pattern}"; then
        delete_rule_prio "$_prio"
        "$@" || die "failed to add rule prio $_prio: $*"
    fi
}

pin_route() {
    _dst="$1"; _dev="$2"; _src="$3"
    if [ -n "$_src" ]; then
        ip -4 route replace "$_dst" dev "$_dev" src "$_src" 2>/dev/null \
            || ip -4 route replace "$_dst" dev "$_dev" 2>/dev/null || true
    else
        ip -4 route replace "$_dst" dev "$_dev" 2>/dev/null || true
    fi
}

fail_inc() {
    _n=$(cat "$FAIL_COUNTER_FILE" 2>/dev/null || echo 0)
    _n=$((_n + 1)); echo "$_n" > "$FAIL_COUNTER_FILE"; echo "$_n"
}
fail_reset() { echo 0 > "$FAIL_COUNTER_FILE"; }
fail_get()   { cat "$FAIL_COUNTER_FILE" 2>/dev/null || echo 0; }

# `wg show` for either tool — AmneziaWG ifaces answer to `awg`, plain WG to `wg`.
# The wrong tool errors with no output, so concatenating is safe.
wgshow() { awg show "$@" 2>/dev/null; wg show "$@" 2>/dev/null; }

# Live tunnel handshake age in seconds (huge number if never), for one iface.
wg_handshake_age() {
    _hs=$(wgshow "${1:-$VPN_IFACE}" latest-handshakes | awk 'NR==1{print $2}')
    [ -n "$_hs" ] && [ "$_hs" -gt 0 ] 2>/dev/null && echo $(( $(date +%s) - _hs )) || echo 999999
}
