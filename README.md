# wg-split

Turn an OpenWrt router into a **local, self-contained split-tunnel gateway**.
LAN traffic is policy-routed over one of several WireGuard/AmneziaWG tunnels with
**priority failover**; blocked/foreign IPs ride the VPN, RU/CN stays direct, and
optional **zapret** does DPI-bypass on WAN. Everything is configured locally via
**UCI / LuCI** — no dashboard, no API, no tokens.

```
[LAN device] ─▶ [tunnel #1] ─▶ … failover … ─▶ [tunnel #N]
              └▶ direct (WAN) ─▶ zapret DPI-bypass for RU/clearnet
```

## What it does

nftables marks → `ip rule` → table 200 → the active tunnel. The policy chains are
regenerated from UCI by `wg-split-apply`; the `wg-split` service runs the failover
loop and self-heals the IP sets.

- **`blocklist` mode (default):** only the `ipsum` set (blocked/foreign IPs) rides
  the VPN; everything else exits WAN with zapret. RU/CN stays direct.
- **`full` mode:** default route via VPN; the direct list is the WAN exception.
- **`split` mode:** only your explicit VPN lists/domains ride the VPN.

Lists are **downloaded by URL** and refreshed daily (cron): an IP list → VPN
(`ipsum`), an IP list → direct (`ru/cn`, also feeds the zapret bypass), and
optional **domain** lists tagged at dnsmasq resolve time. You can also add CIDRs,
domains, and per-device pins by hand in LuCI.

## Failover

List several tunnel interfaces with a priority. Each tick the service:

1. keeps the current tunnel if it's healthy (`ping -I <iface>` a target through it);
2. **restarts a stuck tunnel first** (WG often unsticks on `ifdown/ifup`);
3. otherwise probes the others **non-disruptively** (brings a candidate up in
   parallel and pings through it — the live path is never torn down) and switches
   to the first healthy one, always preferring the highest priority;
4. if no tunnel works and zapret is available → WAN fallback with the VPN IPs
   pulled **out** of `nozapret` so zapret DPI-bypasses them on WAN;
5. if zapret is unavailable/failing → plain WAN (or, with the kill switch on,
   table 200 is blackholed so policy traffic never leaks).

It always tries to recover toward priority #1. The check interval is set in LuCI.

## Install

OpenWrt 24.10+ (apk). Build the two packages in CI (see `.github/workflows/build.yml`)
or with an OpenWrt SDK, then:

```sh
apk add ./wg-split-*.apk ./luci-app-wg-split-*.apk
```

`zapret` is optional — install it separately if you want the DPI-bypass rung; it's
detected at runtime.

## Configure

1. Create your WireGuard/AmneziaWG tunnel interface(s) the normal way under
   **Network → Interfaces** (the app does not manage WG keys/params).
2. Open **Services → wg-split**: pick mode, add each tunnel interface with a
   priority, set the list URLs and the failover interval, toggle zapret, and add
   any manual CIDRs/domains/device pins. Save & Apply.

CLI: `wg-split-status` (snapshot), `wg-split-apply` (regenerate from UCI),
`wg-split-disable` (emergency WAN-only), `wg-split-uninstall` (teardown),
`logread -e wg-split` (service log). Config lives in `/etc/config/wg-split`.

## Files

| Path | Role |
|------|------|
| `wg-split/files/etc/config/wg-split` | UCI config (global + endpoint + device) |
| `wg-split/files/usr/local/sbin/wg-split-failover` | failover state machine + procd daemon |
| `wg-split/files/usr/local/sbin/wg-split-apply` | regenerate nft/dnsmasq layer from UCI |
| `wg-split/files/usr/local/sbin/wg-split-update-{ipsum,ru,domains}` | list downloaders |
| `wg-split/files/usr/local/sbin/wg-split-sync-nozapret` | rebuild zapret bypass set |
| `wg-split/files/usr/local/lib/wg-split/common.sh` | shared helpers (loads UCI) |
| `luci-app-wg-split/` | LuCI configuration page |
