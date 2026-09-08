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

## 2026-09-08T13:25:56-04:00

### Added

- A bug report issue template, with the exact terminal commands to gather
  the version, network state, and debug log a report needs
  ([`392f2d2`](https://github.com/mattyd-ip/simulnetdevice/commit/392f2d2)).

### Changed

- README: added Uninstall instructions and a dependency list, filling
  gaps in the plugin marketplace's submission checklist
  ([`392f2d2`](https://github.com/mattyd-ip/simulnetdevice/commit/392f2d2)).
