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
  interface, not shared from one default-route sample.
- **Set primary** — pins `ipv4.route-metric` on whichever interface should
  own outbound/default-route traffic and reactivates it, so you choose which
  network wins instead of NetworkManager's built-in wired-beats-wireless
  default.
- **Wi-Fi radio on/off** toggle.
- **Ethernet connect/disconnect** toggle.
- **DHCP / Static IPv4 toggle for Ethernet**, with an inline form
  (address/prefix, gateway, DNS) that pre-fills from the current DHCP lease
  when you switch to Static, so "freeze the IP I already have" is one click.
- **Saved static-IP profiles** — name a set of address/gateway/DNS values
  once (e.g. "Office LAN") and re-apply it later instead of retyping it
  every time you're back on a network that needs a fixed IP. Stored at
  `~/.config/netctl/profiles.json`, separate from this repo.
- **Wi-Fi network scanning, joining, and forgetting** — nearby networks
  (sorted connected/known-first, then by signal), a password prompt for
  networks that need one, a lock icon for anything requiring credentials,
  and a forget button for saved networks. Built directly on Quickshell's
  reactive `WifiDevice`/`WifiNetwork` objects (`connect()`,
  `connectWithPsk()`, `forget()`), so there's no `nmcli` scripting involved.
  The list shows about 5 rows at a time and scrolls for the rest, so a
  dense area with dozens of visible networks doesn't blow out the popup.

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

## Upcoming / planned

- **Per-process bandwidth monitoring.** Deliberately deferred out of the
  initial build because it needs a real privilege-elevation subsystem: the
  only reliable way to attribute network traffic to a specific process on
  Linux is `nethogs` running as root, which means installing it, a one-time
  passwordless-sudo rule (same pattern the built-in `omarchy-dns` helper
  uses), and a persistent privileged process whose streaming output gets
  parsed incrementally in QML. This will be its own follow-up plan rather
  than bolted onto the current one.

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
