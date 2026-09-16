# Changelog

Notable changes to SimulNetDevice, for users deciding whether to update.

**Format:**

- Each entry is headed by a full timestamp (`YYYY-MM-DDTHH:MM:SS±HH:MM`,
  ISO 8601), not just a date.
- Entries are grouped under the category that fits, using
  [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)'s vocabulary:
  Added, Changed, Deprecated, Removed, Fixed, Security.
- One entry per logical change, not per commit. Commits that make up a
  single feature or fix are combined into one entry.
- Every entry ends with a link to the commit(s) it covers.
- No version numbers yet — SimulNetDevice isn't on a release cadence, so
  entries are just chronological. Version headings can be introduced
  later if that changes.

**Template:**

```markdown
## YYYY-MM-DDTHH:MM:SS±HH:MM

### Fixed

- Concise, user-facing description of what changed and why it matters
  ([`abc1234`](https://github.com/mattyd-ip/simulnetdevice/commit/abc1234))
```

---

## 2026-09-15T22:28:52-04:00

### Fixed

- Sustained-ping-loss recovery (the automatic Wi-Fi radio-cycle /
  Ethernet reconnect that runs after ~15s of lost pings) now attempts
  once per outage instead of repeating every ~30-45 seconds for however
  long the outage lasts. During a real internet outage, the repeated
  cycling made it difficult to use the panel at all while it was
  happening
  ([`701f4c5`](https://github.com/mattyd-ip/simulnetdevice/commit/701f4c5)).

### Changed

- Manifest and README descriptions updated to mention more of the
  plugin's features
  ([`1acb450`](https://github.com/mattyd-ip/simulnetdevice/commit/1acb450)).

## 2026-09-15T21:48:38-04:00

### Added

- Configurable ping target — each interface's Ping/Packet Loss stats now
  measure against a user-set IPv4 address instead of a fixed one.
  Default stays `1.1.1.1` for existing installs; click the gear next to
  "Ping" to change it, or turn on "Shared Ping-target" to keep both
  interfaces on the same address
  ([`a1c3b11`](https://github.com/mattyd-ip/simulnetdevice/commit/a1c3b11),
  [`2b0a997`](https://github.com/mattyd-ip/simulnetdevice/commit/2b0a997),
  [`d7346f0`](https://github.com/mattyd-ip/simulnetdevice/commit/d7346f0)).

### Changed

- Manifest version bumped to `0.2.0`, and the plugin-marketplace
  description expanded to also mention Wi-Fi scanning and
  ping/throughput, alongside the existing static-IP-profiles and
  primary-routing mentions
  ([`74910e7`](https://github.com/mattyd-ip/simulnetdevice/commit/74910e7),
  [`655eaa5`](https://github.com/mattyd-ip/simulnetdevice/commit/655eaa5)).
- README screenshot now shows the ping-target editor open, instead of
  only the Static IPv4 panel
  ([`21aabf3`](https://github.com/mattyd-ip/simulnetdevice/commit/21aabf3),
  [`431bbb2`](https://github.com/mattyd-ip/simulnetdevice/commit/431bbb2)).

## 2026-09-08T13:25:56-04:00

Prepared for submission to the Omarchy plugin marketplace.

### Added

- A bug report issue template, with the exact terminal commands to gather
  the version, network state, and debug log a report needs
  ([`9a14780`](https://github.com/mattyd-ip/simulnetdevice/commit/9a14780)).
- README: Uninstall instructions and a dependency list
  ([`9a14780`](https://github.com/mattyd-ip/simulnetdevice/commit/9a14780)).
- README discloses the fixed ping target (`1.1.1.1`, one ICMP echo per
  status refresh per interface) used for latency/packet-loss
  ([`e4869a4`](https://github.com/mattyd-ip/simulnetdevice/commit/e4869a4),
  [`653e392`](https://github.com/mattyd-ip/simulnetdevice/commit/653e392)).

### Changed

- README's screenshot now points at a single root-level `preview.png`
  instead of a duplicate copy
  ([`497f9b9`](https://github.com/mattyd-ip/simulnetdevice/commit/497f9b9)).
