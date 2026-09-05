# netctl

An Omarchy (Quickshell) bar widget for managing Wi-Fi and Ethernet
independently, at the same time.

## Why this exists

The built-in `omarchy.network` widget only ever reports on whichever
interface currently owns the default route (`ip route get`). If Wi-Fi and
Ethernet are both connected — two different networks, say — the built-in
widget shows exactly one of them and hides the other entirely. Every status
query in netctl is scoped directly to a specific interface (`ip`/`nmcli
... dev $iface`) instead, so both show up correctly no matter which one is
carrying the default route.

The built-in widget is left untouched and can be re-enabled as a fallback
(`omarchy plugin enable omarchy.network`) if this one ever breaks.

## Current features

- **Independent Wi-Fi + Ethernet sections**, each showing live status at the
  same time: connection state, SSID/link speed, IP address, gateway, ping,
  packet loss, and download/upload rate + totals — tracked separately per
  interface, not shared from one default-route sample. They lay out as two
  side-by-side columns while both are actually connected, dropping back to
  a single stacked column the moment either one isn't (so an idle,
  disconnected side doesn't keep holding onto half the popup).
- **Set primary** — pins `ipv4.route-metric` on whichever interface should
  own outbound/default-route traffic and reactivates it, so you choose which
  network wins instead of NetworkManager's built-in wired-beats-wireless
  default.
- **Wi-Fi radio on/off** toggle.
- **Ethernet connect/disconnect** toggle.
- **DHCP / Static IPv4 toggle for Ethernet**. The DHCP/Static buttons
  themselves are always visible; clicking "Static" is what opens the
  fields below (saved profiles, "Enter manually…"), and clicking "Static"
  again — or closing the popup — is what tucks them back away. If a
  static profile is actually applied, its name stays visible right under
  the buttons even while the fields are closed. Static mode leads with
  your saved profiles rather than raw fields — the address/gateway/DNS
  entry fields stay hidden behind an "Enter manually…" button, reserved
  for typing a brand-new config or editing one, since applying a saved
  profile never needs them.
- **Saved static-IP profiles** — name a set of address/gateway/DNS values
  once (e.g. "Office LAN") and re-apply it later with one click (applies
  immediately — no need to open the manual-entry fields) instead of
  retyping it every time you're back on a network that needs a fixed IP.
  Stored at `~/.config/netctl/profiles.json`, separate from this repo.
  Whichever profile matches the currently-applied config shows right
  under the DHCP/Static buttons (e.g. "homelab-management"), visible even
  with the fields collapsed.
- **Wi-Fi network scanning, joining, and forgetting** — nearby networks
  (sorted connected/known-first, then by signal), a password prompt for
  networks that need one, a lock icon for anything requiring credentials,
  and a forget button for saved networks. Built directly on Quickshell's
  reactive `WifiDevice`/`WifiNetwork` objects (`connect()`,
  `connectWithPsk()`, `forget()`), so there's no `nmcli` scripting involved.
  The list shows about 4 rows at a time and scrolls for the rest (the
  section header shows the total count), so a dense area with dozens of
  visible networks doesn't blow out the popup.

## Known limitations / non-goals (for now)

- **No WPA-Enterprise (802.1x) networks.** Scanning/joining covers
  WPA2/WPA3-Personal, WEP, and open/OWE networks. Enterprise networks (the
  kind that ask for an identity + password, common on corporate/campus
  Wi-Fi) still need the built-in `omarchy.network` widget.
- **No Wi-Fi band selection or QR-code sharing.** Both stay the built-in
  widget's job for now.
- **IPv4 only.** No IPv6 configuration.
- **Static-IP profiles are Ethernet-only right now**, though the data model
  doesn't assume that — extending the picker to Wi-Fi later is
  straightforward.
- **No per-process bandwidth monitoring**, by choice. Investigated two
  approaches — `nethogs` running as root (needs a persistent privileged
  daemon and a new sudoers rule) and sampling `ss -tip` every few seconds
  (no root needed, but TCP-only) — and decided against adding either: it's
  bloat this plugin doesn't need to stay useful, and other plugins already
  cover this ground.

## Troubleshooting

- **Ethernet shows "Connected" but Gateway is blank, and losing Wi-Fi means
  losing all network access.** This means the DHCP server on whatever the
  cable is plugged into isn't sending a gateway (the DHCP "Router" option)
  in Ethernet's lease — NetworkManager has nothing to build a default route
  from, so Ethernet can only reach its own subnet, not the internet. It's a
  router/DHCP-scope quirk (common on isolated ports, guest VLANs, or
  reservations missing a gateway), not something netctl or NetworkManager
  can detect automatically. Two ways to deal with it:
  - **Static IPv4 toggle** (software-only, always available): use the same
    address Ethernet already had, and the gateway your Wi-Fi is using on
    the same subnet (`Gateway` in the Wi-Fi stats grid) — save it as a
    profile so it re-applies with one click next time.
  - **Physically unplug and replug the cable.** Switching Ethernet back to
    DHCP from this widget (or via plain `nmcli`) already forces a genuine
    fresh DHCP transaction, not a stale renewal — confirmed by watching
    NetworkManager's own logs do a full new lease negotiation. But neither
    that nor `nmcli device disconnect`/`connect` ever drops the physical
    carrier (`/sys/class/net/<iface>/carrier` stays `1` throughout, tested
    live) — some routers/switches only re-evaluate what to hand out on an
    actual link-down/up, which nothing at the NetworkManager level can
    trigger without root (`ip link set dev <iface> down`, which this setup
    intentionally doesn't grant passwordless access to, to avoid adding a
    new privilege-escalation surface). If DHCP keeps coming back without a
    gateway even after switching back from Static, a physical replug is
    the reliable way to actually reset the other end's state.

## Repo layout

| File | Responsibility |
|---|---|
| `manifest.json` | Plugin manifest (id `netctl`, bar-widget) |
| `Panel.qml` | Bar icon + popup shell; combines both sections, cross-wires primary-route comparison |
| `WifiSection.qml` | Wi-Fi status, radio toggle, primary-route control |
| `EthernetSection.qml` | Ethernet status, connect/disconnect, DHCP/Static form, primary-route control |
| `StatsGrid.qml` | Shared per-interface ping/throughput/IP/gateway grid |
| `ProfileList.qml` | Saved static-IP profiles UI + JSON persistence |
| `WifiScanList.qml` | Nearby-network scan list, join/password prompt, forget |
| `Model.js` | Pure parsing/formatting/validation helpers (testable under plain `node`) |
| `docs/plans/` | Implementation plan(s) |

## Development

This repo is symlinked into `~/.config/omarchy/plugins/netctl`, so edits
here are what the running shell loads. After a change:

```bash
omarchy restart shell           # clean reload
omarchy-shell netctl open       # open the popup via IPC
omarchy capture screenshot fullscreen save
```

`Model.js`'s pure functions can be smoke-tested directly:

```bash
node -e 'var M = require("./Model.js"); console.log(M.formatRate(2048))'
```
