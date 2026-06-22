# wg-split common helpers. Sourced (not exec'd) by every wg-split-* script.
# Config now lives in UCI (/etc/config/wg-split) — loaded here into the same
# variable names the scripts have always used. Requires: busybox ash, nft, ip,
# logger, and OpenWrt's /lib/functions.sh (uci config helpers).

# NOTE: OpenWrt's /lib/functions.sh and its config_* helpers are NOT nounset-safe
# — they dereference internal state ($IPKG_INSTROOT, $CONFIG_LIST_STATE, …)
# unguarded, both at load and during config_foreach/config_get at runtime. So the
# scripts that source this file must NOT run with `set -u`, or the failover daemon
# crash-loops every tick. Don't add `set -u` to wg-split-{failover,apply,status}.

# shellcheck disable=SC1091
. /lib/functions.sh
config_load wg-split

# ---- user-tunable knobs (UCI 'global' section) -----------------------------
config_get        MODE            global mode            blocklist
config_get        INTERVAL        global interval        180
config_get_bool   KILLSWITCH      global killswitch      0
config_get        LAN_IFACE       global lan_iface       br-lan
config_get        LAN_CIDR        global lan_cidr        ''

# Auto-detect the LAN subnet(s) from lan_iface's connected (proto kernel) routes,
# so policy marking always follows the real bridge. A stale or blank lan_cidr was
# the #1 "nothing gets routed" gotcha: after renumbering the LAN the saddr-matched
# chains kept matching the old subnet and no client traffic was ever marked. Any
# configured lan_cidr is still unioned in, so it can add extra subnets (e.g. VLANs
# not on lan_iface). Result is a comma-joined, nft-ready list (possibly empty if
# the bridge has no IPv4 yet — callers already treat empty as "sets only").
LAN_CIDR="$(
    { ip -4 route show dev "$LAN_IFACE" proto kernel scope link 2>/dev/null \
        | awk '{print $1}'
      printf '%s\n' "$LAN_CIDR" | tr ', ' '\n'
    } | grep -Ex '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | sort -u | tr '\n' ',' | sed 's/,$//'
)"
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
# Isolated table+rule for health probes: the endpoints run route_allowed_ips=0
# (so an ifup can't hijack main routes), which also means they have no main-table
# route to public targets — the probe installs a scoped route via the candidate's
# own source IP for the duration of the ping. Prio above the wg mark rule.
PROBE_TABLE="201"; PROBE_PRIO="998"
# Separate probe table+prio for wg-split-doctor so a LuCI diagnostics run can't
# repoint/flush the failover daemon's table 201 mid-probe (which would make the
# daemon read a healthy tunnel as failed). Distinct table AND a LOWER-precedence
# (higher-numbered) priority than PROBE_PRIO: if two endpoints share the same
# local src address, the daemon's prio-998 `from <src>` rule still wins the tie,
# so the daemon's own probe is never diverted into the doctor's table. (Worst case
# the doctor reads a slightly-off health for that iface — harmless — rather than
# the daemon failing over a healthy tunnel.) Still well below main (32766), so a
# locally-generated, unmarked probe ping from <src> still selects table 202.
PROBE_TABLE_DIAG="202"; PROBE_PRIO_DIAG="1002"
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

# health probing (ping THROUGH the tunnel iface). count=2 so the first packet
# can wake an idle/keepalive-less tunnel (triggers a handshake) and the second
# still confirms it within a single probe.
HEALTH_PING_COUNT="2"; HEALTH_PING_TIMEOUT="2"; HEALTH_CURL_TIMEOUT="5"
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

# Validate+clean an IPv4/CIDR list on stdin -> stdout: strip CR, trailing
# comments and whitespace, drop anything that isn't a well-formed v4 addr/prefix,
# dedup. Shared by the ipsum/ru updaters (identical rules).
clean_ip_list() {
    awk '
        function vnum(x, lo, hi) { return x ~ /^[0-9]+$/ && x >= lo && x <= hi }
        function valid(line, a, n) {
            n = split(line, a, "[./]")
            return n == 5 && vnum(a[1],0,255) && vnum(a[2],0,255) \
                && vnum(a[3],0,255) && vnum(a[4],0,255) && vnum(a[5],0,32)
        }
        { l = $0; sub(/\r$/, "", l); sub(/[ \t]*#.*/, "", l); gsub(/[ \t]/, "", l)
          if (l == "" || !valid(l) || seen[l]++) next
          print l }
    '
}

# Emit a single compact `flush set; add element { a,b,c }` nft command stream for
# set "$1 $2" from a cleaned list on stdin. ONE comma-block (not per-line add) —
# parses in ~10MB vs OOM at 38k+ entries on 240MB routers. Shared by ipsum/ru/noz.
emit_nft_set_block() {
    printf 'flush set %s %s\n' "$1" "$2"
    printf 'add element %s %s {\n' "$1" "$2"
    awk 'NR > 1 { printf "," } { printf "%s", $0 } END { print "" }'
    printf '}\n'
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

# ---- firewall sanity (query helpers) ---------------------------------------
# wg-split owns ROUTING (marks + table 200) but never touches the firewall — a
# tunnel iface still needs a firewall zone (masq on) and lan->that-zone
# forwarding, or fw4 REJECTs the forwarded LAN->tunnel packets and the tunnel
# looks dead though it's up. These read the firewall config with `uci` directly
# (NOT OpenWrt's config_load, which would clobber the wg-split config context
# that config_foreach endpoint/device callers rely on).

# Mirror fw4's parse_bool (see OpenWrt fw4.uc): 1/on/true/yes/enabled (any case)
# are true, everything else (0/off/false/no/disabled/unset/garbage) is false.
fw_bool() {
    case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in
        1|on|true|yes|enabled) return 0 ;;
        *) return 1 ;;
    esac
}

# Is a firewall section one fw4 actually applies to our IPv4 LAN->tunnel path?
# i.e. not disabled (enabled defaults ON when unset) and not ipv6-only (family
# unset/any/both/ipv4). wg-split routes only IPv4, so an ipv6-only zone/forwarding
# leaves IPv4 traffic rejected and must not count as covering the endpoint. $1 =
# section selector, e.g. "@zone[2]" / "@forwarding[0]".
fw_sec_active() {
    _e="$(uci -q get "firewall.$1.enabled" 2>/dev/null)"
    [ -n "$_e" ] && ! fw_bool "$_e" && return 1
    case "$(uci -q get "firewall.$1.family" 2>/dev/null | tr 'A-Z' 'a-z')" in
        ''|any|both|ipv4|4) return 0 ;;
        *) return 1 ;;
    esac
}

# Echo the firewall zone name covering logical iface $1; non-zero if none. Mirrors
# fw4: a zone matches via its `network` OR `device` list (also resolving the
# network's own L3 device); disabled / ipv6-only zones are ignored. (Glob device
# patterns like `tun+` aren't expanded — at worst a spurious warning, never a
# wrong route, since wg-split only warns here.)
fw_zone_of_net() {
    _want="$1"
    _wantdev="$(uci -q get "network.$1.device" 2>/dev/null)"   # network's L3 device, if any
    _fz=0
    while [ -n "$(uci -q get "firewall.@zone[$_fz]" 2>/dev/null)" ]; do
        if fw_sec_active "@zone[$_fz]"; then
            for _m in $(uci -q get "firewall.@zone[$_fz].network" 2>/dev/null) \
                      $(uci -q get "firewall.@zone[$_fz].device"  2>/dev/null); do
                if [ "$_m" = "$_want" ] || { [ -n "$_wantdev" ] && [ "$_m" = "$_wantdev" ]; }; then
                    uci -q get "firewall.@zone[$_fz].name"; return 0
                fi
            done
        fi
        _fz=$((_fz + 1))
    done
    return 1
}

# Is masquerading enabled on the (active) zone named $1? masq is an fw4 bool.
fw_zone_has_masq() {
    _fz=0
    while [ -n "$(uci -q get "firewall.@zone[$_fz]" 2>/dev/null)" ]; do
        if [ "$(uci -q get "firewall.@zone[$_fz].name" 2>/dev/null)" = "$1" ] \
           && fw_sec_active "@zone[$_fz]"; then
            fw_bool "$(uci -q get "firewall.@zone[$_fz].masq" 2>/dev/null)"
            return
        fi
        _fz=$((_fz + 1))
    done
    return 1
}

# Is there an active (enabled, IPv4) firewall forwarding src zone $1 -> dest $2?
fw_has_forwarding() {
    _ff=0
    while [ -n "$(uci -q get "firewall.@forwarding[$_ff]" 2>/dev/null)" ]; do
        if fw_sec_active "@forwarding[$_ff]" \
           && [ "$(uci -q get "firewall.@forwarding[$_ff].src"  2>/dev/null)" = "$1" ] \
           && [ "$(uci -q get "firewall.@forwarding[$_ff].dest" 2>/dev/null)" = "$2" ]; then
            return 0
        fi
        _ff=$((_ff + 1))
    done
    return 1
}

# Firewall zone carrying the LAN — the src side of the lan->tunnel forwarding.
# Tries $LAN_IFACE's network(s), then $LAN_IFACE bound directly (by device), then
# the conventional 'lan'. Empty if it can't be resolved (the caller then skips the
# forwarding check to avoid false warnings).
fw_lan_zone() {
    for _ln in $(uci show network 2>/dev/null \
            | sed -n "s/^network\.\([^.]*\)\.device='\{0,1\}${LAN_IFACE}'\{0,1\}\$/\1/p"); do
        _lz="$(fw_zone_of_net "$_ln")" && { echo "$_lz"; return 0; }
    done
    _lz="$(fw_zone_of_net "$LAN_IFACE")" && { echo "$_lz"; return 0; }
    _lz="$(fw_zone_of_net lan)"          && { echo "$_lz"; return 0; }
    return 1
}

# ---- list-updater mutex ----------------------------------------------------
# The daily cron AND the Save&Apply / daemon self-heal both fire the list
# updaters, so two copies can run at once; the loser's redundant download then
# fails curl and spams ERROR into the log. Serialize on a flock. Degrades to a
# plain run if flock isn't installed. Call as `single_run <tag>` near the top of
# an updater (uses fd 9).
#
# Two intents, by WG_SPLIT_WAIT_LOCK:
#   unset/0 (cron): a concurrent run already refreshes the same list with the same
#                   UCI, so just skip — exit cleanly, no ERROR spam.
#   1 (Save&Apply / self-heal): the new UCI (e.g. a changed list URL) MUST be
#                   applied, so don't drop it — wait out the holder, then run.
single_run() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"/tmp/wg-split-$1.lock" || return 0
    if [ "${WG_SPLIT_WAIT_LOCK:-0}" = "1" ]; then
        # busybox flock has no -w; poll -n up to WG_SPLIT_LOCK_WAIT seconds.
        _sr_n=0
        until flock -n 9; do
            _sr_n=$((_sr_n + 1))
            [ "$_sr_n" -ge "${WG_SPLIT_LOCK_WAIT:-240}" ] \
                && { log "$1: timed out waiting for lock — not refreshed this run"; exit 1; }
            sleep 1
        done
    else
        flock -n 9 || { log "$1: another run in progress — skipping"; exit 0; }
    fi
}

# `wg show` for either tool — AmneziaWG ifaces answer to `awg`, plain WG to `wg`.
# The wrong tool errors with no output, so concatenating is safe.
wgshow() { awg show "$@" 2>/dev/null; wg show "$@" 2>/dev/null; }

# Live tunnel handshake age in seconds (huge number if never), for one iface.
wg_handshake_age() {
    _hs=$(wgshow "${1:-$VPN_IFACE}" latest-handshakes | awk 'NR==1{print $2}')
    [ -n "$_hs" ] && [ "$_hs" -gt 0 ] 2>/dev/null && echo $(( $(date +%s) - _hs )) || echo 999999
}

# ---- iface / zapret predicates (shared by failover, status, doctor) --------
iface_present() { ip link show dev "$1" >/dev/null 2>&1; }

# Health-probe an iface end-to-end. Because endpoints run route_allowed_ips=0,
# they have no main-table route to public targets and a locally-generated ping is
# not policy-routed through table 200 — so `ping -I iface` alone finds no route.
# Install an ISOLATED probe route (default via the iface in a probe table, selected
# by the iface's own source IP) for the duration of the ping, touching neither the
# main table, table 200, nor the DoH pins. Works for the active iface and parallel
# candidates alike. The failover daemon uses the default PROBE_TABLE/PROBE_PRIO;
# wg-split-doctor passes PROBE_TABLE_DIAG/PROBE_PRIO_DIAG so the two never collide.
# Usage: health_ping IFACE [TABLE] [PRIO]
health_ping() {
    _hpif="$1"; _hptbl="${2:-$PROBE_TABLE}"; _hpprio="${3:-$PROBE_PRIO}"
    _hpsrc="$(iface_src_ip "$_hpif")"
    [ -n "$_hpsrc" ] || return 1
    ip -4 rule del from "$_hpsrc" table "$_hptbl" priority "$_hpprio" 2>/dev/null || true
    ip -4 route replace default dev "$_hpif" table "$_hptbl" 2>/dev/null || true
    ip -4 rule add from "$_hpsrc" table "$_hptbl" priority "$_hpprio" 2>/dev/null || true
    _hpok=1
    for _t in $HEALTH_TARGETS; do
        if ping -c "$HEALTH_PING_COUNT" -W "$HEALTH_PING_TIMEOUT" -I "$_hpif" -q "$_t" >/dev/null 2>&1; then
            _hpok=0; break
        fi
    done
    ip -4 rule del from "$_hpsrc" table "$_hptbl" priority "$_hpprio" 2>/dev/null || true
    ip -4 route flush table "$_hptbl" 2>/dev/null || true
    return "$_hpok"
}
zapret_running()   { (ps w 2>/dev/null || ps 2>/dev/null) | grep -q '[n]fqws'; }
zapret_available() {
    [ -x "$ZAPRET_INIT" ] && return 0
    [ -x /opt/zapret/nfq/nfqws ] && return 0
    command -v nfqws >/dev/null 2>&1 && return 0
    zapret_running && return 0
    return 1
}
