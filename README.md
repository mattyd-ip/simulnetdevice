# SimulNetDevice

An Omarchy (Quickshell) plugin for managing Wi-Fi and Ethernet
independently, at the same time.

## Why this exists

The built-in `omarchy.network` plugin only ever reports on whichever
interface currently owns the default route. If Wi-Fi and Ethernet are both
connected — two different networks, say — the built-in plugin shows exactly
one of them and hides the other entirely. Every status query in SimulNetDevice is
scoped directly to a specific interface instead, so both show up correctly
no matter which one is carrying the default route.

The built-in plugin is left untouched and can be re-enabled as a fallback
(`omarchy plugin enable omarchy.network`) if this one ever breaks.

## Running alongside the built-in plugin

You don't have to disable `omarchy.network` to use SimulNetDevice. If it's still
enabled, SimulNetDevice shows a small banner with a "Disable it" button (or the
equivalent `omarchy plugin disable omarchy.network` command, if you'd
rather run it yourself) and a "Keep both" button that remembers your
choice for good — it won't ask again unless you delete
`~/.config/simulnetdevice/hide-network-conflict-notice`.

Running both at once is safe day to day. The one thing to know: if both
popups happen to be open at the same time, Wi-Fi network scanning can
briefly stop in whichever one you leave open — it corrects itself as soon
as you reopen either popup, so at worst you see a stale nearby-networks
list for a moment. See `ARCHITECTURE.md` if you want the technical reason
why.

## Installation

```bash
omarchy plugin add <this-repo's-git-url> --enable
```

Or, from a local clone:

```bash
git clone <this-repo's-git-url> ~/.config/omarchy/plugins/simulnetdevice
omarchy plugin enable simulnetdevice
```

## Current features

- **Independent Wi-Fi + Ethernet sections**, each showing live status at the
  same time: connection state, SSID/link speed, IP address, gateway, ping,
  packet loss, and download/upload rate + totals — tracked separately per
  interface, not shared from one default-route sample. They lay out as two
  side-by-side columns while both are actually connected, dropping back to
  a single stacked column the moment either one isn't (so an idle,
  disconnected side doesn't keep holding onto half the popup).
- **Set primary** — choose which connected network handles your internet
  traffic, instead of NetworkManager's built-in wired-beats-wireless
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
  Stored at `~/.config/simulnetdevice/profiles.json`, separate from this repo.
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
- **Automatic recovery from a stuck connection** — if ping loss to the
  internet is sustained rather than a one-off blip, Wi-Fi cycles its radio
  off and back on and Ethernet disconnects and reconnects (the same fix
  you'd do by hand), each with a cooldown afterward so a condition this
  can't actually fix doesn't turn into repeated flapping. Separately, an
  Ethernet Apply that fails because the cable isn't plugged in yet retries
  automatically the moment it is, and a failure with the cable already
  present gets a few automatic retries before showing a real error.
- **Full keyboard navigation** — `j`/`k` (or ↓/↑) move between control
  groups, `h`/`l` (or ←/→) move between items in the current group and hop
  to the other column when Wi-Fi and Ethernet are side by side, `Space`/
  `Enter` activates whatever's highlighted, `x` forgets a highlighted
  Wi-Fi network or deletes a highlighted saved Ethernet profile, `Tab`
  switches to the next plugin, and `Escape` closes the popup (or
  cancels a password/profile-name entry while typing).

## Tested on

Omarchy 4.0.2 (Arch Linux, kernel 7.1.9-arch1-2) on a Lenovo ThinkPad E15
Gen 2, NetworkManager (`nmcli` 1.58.1), one Wi-Fi adapter + one wired
Ethernet adapter. See Known limitations below for what's untested (a
second adapter of the same type, non-Arch systems, etc.).

## Known limitations

- **No WPA-Enterprise (802.1x) networks.** Scanning/joining covers
  WPA2/WPA3-Personal, WEP, and open/OWE networks. Enterprise networks (the
  kind that ask for an identity + password, common on corporate/campus
  Wi-Fi) still need the built-in `omarchy.network` plugin.
- **No QR-code Wi-Fi sharing, speed test shortcut, or system-wide DNS
  provider quick-switch.** These are the built-in plugin's job (the first
  two are just shortcut buttons to the separate `omarchy.wifiqr` and
  `omarchy.speedtest` plugins, both still reachable on their own if
  enabled; the DNS quick-switch changes DNS for the whole system, not one
  interface).
- **IPv4 only.** No IPv6 configuration.
- **Static-IP profiles are Ethernet-only.**
- **No per-process bandwidth monitoring.** Other plugins already cover this
  ground.
- **One Wi-Fi + one Ethernet interface, assumed.** A second adapter of the
  same type (a second Wi-Fi card, or an onboard + dock/USB Ethernet NIC) is
  invisible to SimulNetDevice — no error, it just never appears.

## Troubleshooting

**Ping spikes, packet loss, or a blank Gateway (including a connection
that shows "Connected" but has no real network access)** — most often
right after changing a connection or a setting (switching networks,
toggling the radio, applying a static IP, and similar).

Start by closing and reopening the panel — this refreshes every value
from scratch and clears up most of these on its own. If it doesn't, the
fix is to actually drop and re-establish the physical link, not just
change a setting in the panel:

- **Wi-Fi**: toggle the radio off and back on (from the panel, or
  physically if your device has a hardware switch), disconnect and
  reconnect to the same network, or connect to a different SSID and back.
- **Ethernet**: reseat the cable (unplug and replug it), or apply a
  **Static IPv4** profile for the network instead of DHCP.

This isn't something SimulNetDevice or NetworkManager detects or fixes on its
own. It's a lower-level issue with how this particular combination of
plugin, NetworkManager, OS, and this workstation's hardware handles the
connection — not something seen with other similar tools.
