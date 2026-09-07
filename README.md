# netctl

An Omarchy (Quickshell) bar widget for managing Wi-Fi and Ethernet
independently, at the same time.

## Why this exists

The built-in `omarchy.network` widget only ever reports on whichever
interface currently owns the default route. If Wi-Fi and Ethernet are both
connected — two different networks, say — the built-in widget shows exactly
one of them and hides the other entirely. Every status query in netctl is
scoped directly to a specific interface instead, so both show up correctly
no matter which one is carrying the default route.

The built-in widget is left untouched and can be re-enabled as a fallback
(`omarchy plugin enable omarchy.network`) if this one ever breaks.

## Installation

```bash
omarchy plugin add <this-repo's-git-url> --enable
```

Or, from a local clone:

```bash
git clone <this-repo's-git-url> ~/.config/omarchy/plugins/netctl
omarchy plugin enable netctl
```

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
- **Wi-Fi band selection** — pin the connection to 2.4/5/6GHz or leave it on
  Auto; only offered when the network actually answers on more than one
  band. The live band always shows next to the network name regardless.
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
  and a forget button for saved networks. The list shows about 4 rows at a
  time and scrolls for the rest (the section header shows the total count),
  so a dense area with dozens of visible networks doesn't blow out the
  popup.
- **Full keyboard navigation** — `j`/`k` (or ↓/↑) move between control
  groups, `h`/`l` (or ←/→) move between items in the current group and hop
  to the other column when Wi-Fi and Ethernet are side by side, `Space`/
  `Enter` activates whatever's highlighted, `x` forgets a highlighted
  Wi-Fi network or deletes a highlighted saved Ethernet profile, `Tab`
  switches to the next bar widget, and `Escape` closes the popup (or
  cancels a password/profile-name entry while typing).

## Tested on

Omarchy 4.0.2 (Arch Linux, kernel 7.1.9-arch1-2), NetworkManager (`nmcli`
1.58.1), one Wi-Fi adapter + one wired Ethernet adapter. See Known
limitations below for what's untested (a second adapter of the same type,
non-Arch systems, etc.).

## Known limitations / non-goals (for now)

- **No WPA-Enterprise (802.1x) networks.** Scanning/joining covers
  WPA2/WPA3-Personal, WEP, and open/OWE networks. Enterprise networks (the
  kind that ask for an identity + password, common on corporate/campus
  Wi-Fi) still need the built-in `omarchy.network` widget.
- **No QR-code Wi-Fi sharing, speed test shortcut, or system-wide DNS
  provider quick-switch.** These stay the built-in widget's job for now
  (the first two are just shortcut buttons to the separate `omarchy.wifiqr`
  and `omarchy.speedtest` plugins, both still reachable on their own if
  enabled; the DNS quick-switch changes DNS for the whole system, not one
  interface, which is out of scope here).
- **IPv4 only.** No IPv6 configuration.
- **Static-IP profiles are Ethernet-only right now.**
- **No per-process bandwidth monitoring.** Other plugins already cover this
  ground.
- **One Wi-Fi + one Ethernet interface, assumed.** A second adapter of the
  same type (a second Wi-Fi card, or an onboard + dock/USB Ethernet NIC) is
  invisible to netctl — no error, it just never appears.

## Troubleshooting

**Connection shows "Connected" but Gateway is blank, and you lose all
network access if the other interface goes down.**

This means the DHCP server on the router isn't sending a gateway in that
lease, so the interface can only reach its own subnet, not the internet.
It's not something netctl or NetworkManager can detect or fix
automatically, and the fix differs by interface:

- **Wi-Fi**: disconnect and reconnect the network (toggle the radio off/on,
  or reconnect from the nearby-networks list). This forces a fresh 802.11
  association and a new DHCP lease.
- **Ethernet**: switching back to DHCP from this widget already forces a
  fresh DHCP request, but some routers only hand out a complete lease on an
  actual link down/up, which nothing here can trigger without root. Two
  options: apply a **Static IPv4** profile with an address/gateway you
  already know are correct, or **physically unplug and replug the cable**.
