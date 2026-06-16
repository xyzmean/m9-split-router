# wg-split common helpers. Sourced (not exec'd) by every wg-split-* script and
# by m9-rtr-agent. Requires: busybox ash, nft, ip, logger.

CONF_FILE="${WG_SPLIT_CONF:-/etc/wg-split/wg-split.conf}"
[ -r "$CONF_FILE" ] || { echo "FATAL: $CONF_FILE not readable" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF_FILE"

# Policy-derived knobs live in a second file the agent rewrites on every rev so
# the static conf above stays operator-owned. Both are sourced; policy wins.
POLICY_ENV="${POLICY_ENV:-/etc/wg-split/policy.env}"
# shellcheck disable=SC1090
[ -r "$POLICY_ENV" ] && . "$POLICY_ENV"

# Defaults for the policy knobs (so scripts work before the agent's first sync).
MODE="${MODE:-blocklist}"
IPSUM_ENABLED="${IPSUM_ENABLED:-1}"
KILLSWITCH="${KILLSWITCH:-0}"
VPN_SET="${VPN_SET:-wg_split_vpn_v4}"
DIRECT_SET="${DIRECT_SET:-wg_split_direct_v4}"
# The WG mesh range. Dashboard configs assign the tunnel IP as /32, so without
# an explicit route the router has NO return path to the mesh (only the
# dashboard host-route the watchdog pins) — mesh ssh/ping would time out.
MESH_CIDR="${MESH_CIDR:-10.8.0.0/16}"
# Node CIDR for the auto-mesh (10.90.x.x). Used for mesh health probes and
# anti-loop rules when the tunnel endpoint is a mesh address.
MESH_NODE_CIDR="${MESH_NODE_CIDR:-10.90.0.0/24}"
# Dashboard's mesh /32 address (set by the mesh roster via /api/rtr/sync).
# Used as a fallback sync endpoint and for mesh health probing.
MESH_DASHBOARD_URL="${MESH_DASHBOARD_URL:-}"

log()  { logger -t "${LOG_TAG:-wg-split}" "$*"; }
die()  { log "ERROR: $*"; echo "ERROR: $*" >&2; exit 1; }
warn() { log "WARN: $*"; }

# Count IPv4 elements in an nft set without tripping `set -e` on empty.
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

read_state()  { cat "$STATE_FILE" 2>/dev/null || true; }
write_state() { printf '%s\n' "$1" > "$STATE_FILE"; }

fail_inc() {
    _n=$(cat "$FAIL_COUNTER_FILE" 2>/dev/null || echo 0)
    _n=$((_n + 1)); echo "$_n" > "$FAIL_COUNTER_FILE"; echo "$_n"
}
fail_reset() { echo 0 > "$FAIL_COUNTER_FILE"; }
fail_get()   { cat "$FAIL_COUNTER_FILE" 2>/dev/null || echo 0; }

all_src_cidrs() {
    if [ -n "${EXTRA_SRC_CIDRS:-}" ]; then echo "$LAN_CIDR $EXTRA_SRC_CIDRS"
    else echo "$LAN_CIDR"; fi
}

# `wg show` for either tool — AmneziaWG ifaces answer to `awg`, plain WG to `wg`.
# The wrong tool errors with no output, so concatenating is safe.
wgshow() { awg show "$@" 2>/dev/null; wg show "$@" 2>/dev/null; }

# Live VPN tunnel handshake age in seconds (huge number if never), for status.
wg_handshake_age() {
    _hs=$(wgshow "$VPN_IFACE" latest-handshakes | awk 'NR==1{print $2}')
    [ -n "$_hs" ] && [ "$_hs" -gt 0 ] 2>/dev/null && echo $(( $(date +%s) - _hs )) || echo 999999
}
