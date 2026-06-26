#!/usr/bin/env bats
# Unit tests for wg-split's pure logic (no router, no uci/nft/ip).
# Run: bats tests/   — or off-box, the doctor selftest: WG_SPLIT_SELFTEST=1 wg-split-doctor

load helper

# ---- clean_ip_list: validate/strip/dedup an IPv4-CIDR list ------------------
# Note: this helper feeds nft interval sets and requires CIDR notation — a bare
# host address (no /prefix) is intentionally rejected (the ipsum/ru lists are
# all subnets). Tests pin that contract.
setup_clean() { load_fn "$COMMON_SH" clean_ip_list; }

@test "clean_ip_list keeps valid v4/cidr in order" {
    setup_clean
    out="$(printf '%s\n' '1.2.3.4/32' '10.0.0.0/8' | clean_ip_list)"
    [ "$out" = "$(printf '1.2.3.4/32\n10.0.0.0/8')" ]
}

@test "clean_ip_list strips comments, CR, whitespace and dedups" {
    setup_clean
    out="$(printf '%s\r\n' '  1.1.1.1/32  # dns' '1.1.1.1/32' '' 'not.an.ip' '256.1.1.1/24' '8.8.8.8/33' | clean_ip_list)"
    [ "$out" = "1.1.1.1/32" ]
}

@test "clean_ip_list rejects bare hosts, out-of-range octets and bad prefixes" {
    setup_clean
    out="$(printf '%s\n' '1.1.1.1' '300.0.0.1/24' '1.2.3.4/40' '1.2.3' 'abc' | clean_ip_list)"
    [ -z "$out" ]
}

# ---- fw_bool: mirror fw4's parse_bool --------------------------------------
@test "fw_bool true values" {
    load_fn "$COMMON_SH" fw_bool
    for v in 1 on true yes enabled ON True YES Enabled; do
        run fw_bool "$v"; [ "$status" -eq 0 ] || { echo "expected true for '$v'"; return 1; }
    done
}

@test "fw_bool false / unset / garbage values" {
    load_fn "$COMMON_SH" fw_bool
    for v in 0 off false no disabled "" maybe 2; do
        run fw_bool "$v"; [ "$status" -ne 0 ] || { echo "expected false for '$v'"; return 1; }
    done
}

# ---- json_esc: escape backslash + double-quote ------------------------------
@test "json_esc escapes backslash and quote" {
    load_fn "$DOCTOR_SH" json_esc
    [ "$(json_esc 'a"b\c')" = 'a\"b\\c' ]
    [ "$(json_esc 'plain')" = 'plain' ]
}

# ---- _rank: severity ordering OK<WARN<FIXABLE<FAIL --------------------------
@test "_rank orders severities" {
    load_fn "$DOCTOR_SH" _rank
    [ "$(_rank OK)" -eq 0 ]
    [ "$(_rank WARN)" -gt "$(_rank OK)" ]
    [ "$(_rank FIXABLE)" -gt "$(_rank WARN)" ]
    [ "$(_rank FAIL)" -gt "$(_rank FIXABLE)" ]
    [ "$(_rank bogus)" -eq 0 ]
}

# ---- endpoint parsing: priority sort + type default (design §2.2) -----------
# Stub OpenWrt's config layer with a fixture, then run the REAL endpoint helpers.
load_endpoint_helpers() {
    load_fn "$COMMON_SH" _collect_endpoint
    load_fn "$COMMON_SH" endpoints_by_priority
    load_fn "$COMMON_SH" top_endpoint
    load_fn "$COMMON_SH" _ep_type_emit
    load_fn "$COMMON_SH" ep_type
    load_fn "$COMMON_SH" is_endpoint
}

# Stub OpenWrt's config layer: config_foreach forwards extra args to the callback
# (as the real one does: `config_foreach cb type extra…` -> `cb section extra…`);
# config_get returns the fixture value or the default when unset/empty.
config_foreach() { local cb="$1"; shift 2; for s in $SECTIONS; do "$cb" "$s" "$@"; done; }
config_get() { eval "$1=\"\${cfg_${2}_${3}:-$4}\""; }

@test "endpoints_by_priority orders best (lowest number) first, skips ifaceless" {
    load_endpoint_helpers
    SECTIONS="a b c d"
    cfg_a_iface=wg2 cfg_a_priority=2
    cfg_b_iface=wg1 cfg_b_priority=1
    cfg_c_iface=wg9 cfg_c_priority=9
    cfg_d_iface=""  cfg_d_priority=5     # no iface -> dropped
    run endpoints_by_priority
    [ "$status" -eq 0 ]
    [ "$output" = "wg1 wg2 wg9 " ] || { echo "got: [$output]"; return 1; }
}

@test "top_endpoint is the lowest priority number" {
    load_endpoint_helpers
    SECTIONS="a b"
    cfg_a_iface=awg0 cfg_a_priority=3
    cfg_b_iface=wg0  cfg_b_priority=1
    [ "$(top_endpoint)" = "wg0" ]
}

@test "ep_type defaults to wg and honors explicit type" {
    load_endpoint_helpers
    SECTIONS="a b"
    cfg_a_iface=wg0  cfg_a_priority=1            # no type -> wg
    cfg_b_iface=sb0  cfg_b_priority=2 cfg_b_type=singbox
    [ "$(ep_type wg0)" = "wg" ]
    [ "$(ep_type sb0)" = "singbox" ]
}

# Security gate for privileged firewall fixes: only configured endpoints pass,
# so the ubus action can never target a foreign iface like `wan`.
@test "is_endpoint accepts configured ifaces and rejects foreign ones" {
    load_endpoint_helpers
    SECTIONS="a b"
    cfg_a_iface=wg0  cfg_a_priority=1
    cfg_b_iface=awg0 cfg_b_priority=2
    run is_endpoint wg0;  [ "$status" -eq 0 ]
    run is_endpoint awg0; [ "$status" -eq 0 ]
    run is_endpoint wan;  [ "$status" -ne 0 ]
    run is_endpoint "";   [ "$status" -ne 0 ]
    run is_endpoint wg;   [ "$status" -ne 0 ]   # substring must not match
}
