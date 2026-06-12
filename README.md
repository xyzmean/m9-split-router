# m9-split-router

Deploy a home/office router as a **split-tunnel gateway** into the M9 WireGuard
network. Every device on the router's LAN reaches the internet through the VPN
entry point — which then geo-splits traffic (ru/cn exits locally, blocked +
Google/WhatsApp exit via m9-13) — with **zero per-device configuration**.

The LAN is routed **transparently** (no NAT on the router), so its subnet is a
real, reachable part of the VPN mesh. You advertise that subnet from the
dashboard, which pushes it to every entry point live (`AllowedIPs += <subnet>`).

## How it fits together

```
[LAN device] -> [this router, wg] -> [entry point m9-14/m9-16] -> ru? local exit
                                                                -> blocked? m9-13 (WARP)
```

- The router has a WireGuard peer IP (e.g. `10.8.0.2`) plus one or more LAN
  subnets (e.g. `192.168.50.0/24`).
- On every entry point the router peer's `AllowedIPs = 10.8.0.2/32 + <LAN
  subnets>`, so return/mesh traffic to the LAN is delivered back through it.
- The entry point SNATs tunnel traffic onto its transit IP, so the LAN works the
  same regardless of which entry point the router connects to (clients are
  synced across all of them).

## Setup

1. In the dashboard: add a client (it becomes the router), download its
   `router-<entrypoint>.conf`, and set its **LAN subnet(s)** under the router
   panel. The dashboard propagates the subnets to all entry points immediately.
2. On the router:
   - **Generic Linux** (x86 / Pi running Debian/Ubuntu):
     ```
     sudo ./install.sh -c router-m9-14.conf -l 192.168.50.0/24 -i eth1
     ```
   - **OpenWrt**:
     ```
     ./openwrt-setup.sh router-m9-14.conf 192.168.50.0/24
     ```
3. Change the LAN subnets any time from the dashboard — entry points update live;
   re-run the installer only if the router's own LAN interface/CIDR changes.

`-n` on the Linux installer switches to NAT mode (LAN hidden behind the tunnel
IP) if you do **not** need mesh-inbound access to LAN devices.

Part of the M9 stack — `xyzmean/wgmon-agent`, `xyzmean/wg-dashboard-vue`,
`xyzmean/m9-routes`.
