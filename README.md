# m9-split-router

Turn an OpenWrt router into a **dashboard-managed split-tunnel gateway** for the
M9 WireGuard network. Devices on the router's LAN get policy routing with **zero
per-device config**, and the whole policy is driven **live from the dashboard**.

This is the generalised, auto-provisioned version of the hand-built split that
runs on the reference router (`y1WRT`). Same mechanism, now installable on any
OpenWrt box and remote-controlled.

## What it does

The router connects to an M9 entry point with **AmneziaWG** and policy-routes LAN
traffic with nftables marks → `ip rule` → table 200 → tunnel:

```
[LAN device] ─▶ [router wg0] ─▶ entry point (m9-14 / m9-16) ─▶ m9-13 (WARP) for blocked
              └▶ direct (WAN) ─▶ zapret DPI-bypass for RU/clearnet
```

- **`blocklist` mode (default):** only blocked/foreign IPs (the `ipsum` set) ride
  the VPN; everything else exits the local WAN with **zapret** DPI bypass. RU
  subnets stay direct. The low-overhead "only what's censored goes through the
  tunnel" model.
- **`full` mode:** default route via VPN; `direct_*` entries are the WAN exceptions.
- **`split` mode:** only the explicit `vpn_cidrs` / `vpn_domains` ride the VPN.

On top of the mode you can, from the dashboard:
- force specific **CIDRs or domains** via VPN or direct (domains tagged at DNS
  resolve time through dnsmasq `nftset`),
- pin **individual LAN devices** to vpn / direct,
- pick the **entry point** (the agent re-points the AmneziaWG endpoint live),
- toggle **ipsum / zapret / RU-direct**, and a **killswitch** (drop policy traffic
  instead of leaking to WAN when the tunnel is down).

A `watchdog` (cron */3) self-heals the rules, refreshes the IP sets daily, and
fails over to WAN (or blackholes, under killswitch) if the tunnel dies.

## How the dashboard drives it

`m9-rtr-agent` (a procd service) polls `POST $DASHBOARD/api/rtr/sync` every 30 s
with a router token:

- **up:** status (version, uptime, WAN IP, tunnel handshake age, rx/tx) + the LAN
  device list (from DHCP leases) — shown in the dashboard.
- **down:** `{rev, policy, endpoints}`. When the policy `rev` changes, the agent
  writes `/etc/wg-split/policy.json` and runs `wg-split-apply`, which regenerates
  `/etc/nftables.d/31-wg-split-policy.nft` + the dnsmasq domain sets, switches the
  entry endpoint if needed, reloads `fw4`/dnsmasq, and re-applies routing.

The router never opens an inbound port — it pulls. The token is per-router and
rotatable from the dashboard.

## Setup

1. **Dashboard:** add a client (this becomes the router peer), open it, set its
   **LAN subnet** and click **Enable router management**. Copy the **token** +
   **pubkey** shown, and download the router's `router-<entry>.conf`.
2. **Router** (OpenWrt, with the AmneziaWG + zapret feeds available):
   ```sh
   git clone https://github.com/xyzmean/m9-split-router && cd m9-split-router
   ./install.sh -c router-m9-14.conf -l 10.8.1.0/24 -i br-lan \
                -u https://10.8.0.1:8443 -t <TOKEN> -k <PUBKEY>
   ```
   `-l` is the router's own LAN subnet (e.g. `10.8.1.0/24` behind peer `10.8.0.2`).
3. From then on, change **everything** from the dashboard's router panel — mode,
   lists, per-device, entry point. The agent applies within ~30 s. Re-run the
   installer only if the router's WAN/LAN interfaces or its WG keypair change.

## Files

| Path | Role |
|------|------|
| `install.sh` | OpenWrt bootstrap: packages, AmneziaWG uci iface, stack, agent |
| `files/usr/local/sbin/m9-rtr-agent` | dashboard sync daemon (procd) |
| `files/usr/local/sbin/wg-split-apply` | regenerate nft/dnsmasq layer from `policy.json` |
| `files/usr/local/sbin/wg-split-watchdog` | health, route install, killswitch/WAN fallback |
| `files/usr/local/sbin/wg-split-update-{ipsum,ru}` | daily IP-set refresh |
| `files/usr/local/sbin/wg-split-sync-nozapret` | rebuild zapret bypass set |
| `files/usr/local/sbin/wg-split-{status,disable,uninstall}` | ops |
| `files/etc/nftables.d/30-wg-split.nft` | static nft set definitions |
| `files/etc/wg-split/wg-split.conf.tmpl` | operator-owned static config |

Operations on the router: `wg-split-status` (snapshot), `wg-split-disable`
(emergency WAN-only; watchdog re-enables), `wg-split-uninstall` (full teardown),
`logread -e m9-rtr-agent` (agent log).

Part of the M9 stack — `xyzmean/wgmon-agent`, `xyzmean/wg-dashboard-vue`,
`xyzmean/m9-routes`, `xyzmean/radb-tools`.
