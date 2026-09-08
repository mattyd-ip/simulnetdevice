# Architecture

Orientation for anyone reviewing or extending this codebase — how it's put
together, what's original vs. adapted from elsewhere, and the non-obvious
invariants worth knowing before touching a given file. For end-user docs
see `README.md`; for the dev loop and forward-looking notes see
`DEVELOPMENT.md`.

## Repo layout

| File | Responsibility |
|---|---|
| `manifest.json` | Plugin manifest (id `netctl`, bar-widget) |
| `Panel.qml` | Bar icon + popup shell; combines both sections, cross-wires primary-route comparison, owns the keyboard-cursor controller and the `omarchy.network` conflict banner |
| `WifiSection.qml` | Wi-Fi status, radio toggle, band selection, primary-route control, nearby-network list |
| `EthernetSection.qml` | Ethernet status, connect/disconnect, DHCP/Static form, primary-route control |
| `StatsGrid.qml` | Shared per-interface ping/throughput/IP/gateway grid |
| `ProfileList.qml` | Saved static-IP profiles UI + JSON persistence |
| `WifiScanList.qml` | Nearby-network scan list, join/password prompt, forget |
| `Model.js` | Pure parsing/formatting/validation helpers (testable under plain `node`) |
| `docs/plans/` | Implementation plan(s) |

## Design overview

**Two independent, self-contained sections, not one shared state machine.**
`WifiSection.qml` and `EthernetSection.qml` each own their own `info`
object, `Process`/`Timer` polling, and form state. Neither reads the
default route — every status query is scoped directly to that section's
own interface (`ip`/`nmcli ... dev $iface`), which is the entire reason
this plugin exists instead of the built-in `omarchy.network` plugin (that
plugin reports only whichever interface currently owns the default route,
so a second connected interface is invisible in it). `Panel.qml` is a thin
shell: it instantiates one of each section, lays them out in a `Grid`
(1 or 2 columns depending on `twoColumn`), and picks the bar icon.

**"Set primary" is pairwise by construction.** There is no shared
route-metric coordinator. Each section exposes `routeMetric`,
`isPrimary` (compared against `primaryCompareMetric`), `setRouteMetric()`,
and a `routeMetricApplied` signal. `Panel.qml` wires the two sections
together directly: each one's `primaryCompareMetric` is bound to the
other's live `routeMetric`, and each one's `onRouteMetricApplied` calls
`setRouteMetric(SECONDARY_METRIC)` on the other, by id. This works cleanly
for exactly two interfaces; it does not generalize to N without a real
rewrite (see `DEVELOPMENT.md`'s multi-NIC notes) — a promotion has to
demote every other connected interface, not one named sibling, and this
was the source of the trickiest bugs in the project's history (a feedback
loop and a deadlock — see `git log`), so treat any change here with extra
care and prefer live-testing route-metric changes only in ways that can't
cut the machine's own active connection.

**Per-instance state, not singletons.** Because each section is a normal
QML component instance rather than a global/singleton, its `info`,
`actionProc`, retry/recovery timers, and `actionGeneration` counter are
naturally isolated per instance, with nothing shared across sections.

**`Model.js` holds all the pure logic.** Parsing (`parseKeyValue`),
formatting, validation, and the throughput/ping/route-metric/profile math
all live here with no QML/Quickshell imports, so they're runnable and
testable under plain `node`. QML files call into `Model.js` rather than
reimplementing this logic inline — if you're looking for *why* a status
string is shaped a certain way, or how a rate/average is computed, this is
the file to check first.

**Keyboard navigation is a central controller over two dumb sections.**
`Panel.qml` owns the only cursor state that exists (`cursorSection`,
`cursorGroup`, `cursorItem`) and is the only thing that knows both sections
exist. Each section instead exposes a small, identical interface -- a
`navGroupIds` list plus `navGroupCount(id)` / `navActivate(id, item)` /
`navDelete(id, item)` -- and receives `cursorActive`/`cursorGroup`/
`cursorItem` back as plain input properties, with `cursorGroup` arriving as
`-1` whenever the cursor actually belongs to the other section. Each
section also computes its own `currentGroupId` (the group name the cursor
is on, or `""`), so every control's own `hasCursor` binding is just
`currentGroupId === "id" && cursorItem === N`. Neither section imports or
references the other.

Groups are vertically-stacked content, navigated with `j`/`k`; items within
a group are horizontally-adjacent controls, navigated with `h`/`l`. This is
why the nearby-network list (`WifiSection.qml`) and the saved-profile list
(`EthernetSection.qml`) each generate one group *per row* (`"network-0"`,
`"network-1"`, ... and `"profile-0"`, `"profile-1"`, ...) rather than
packing every row into one group navigated with `h`/`l` -- rows are stacked
top to bottom, so `j`/`k` is what actually matches how they're laid out.
Getting this backwards was an actual bug caught during review: it read as
correct in both cases until it was navigated for real.

`Panel.qml`'s `moveCursor(dx, dy)` is the only code that hands the cursor
from one section's edge to the other's, and it does so differently
depending on `panel.twoColumn`: `j`/`k` spill into the other section only
while stacked (single column), landing on that section's first group when
moving down or its last group when moving up; `h`/`l` spill into the other
*column* only while side by side, preferring a group with the same id
(so leaving "hero" on one side lands on "hero" on the other) and falling
back to "hero" specifically -- not "whatever group the same numeric index
happens to be", which landed on the nearby-network list often enough to
matter, and that list's length changes on its own as background scans
complete, so "the last row" stopped being the actual last row within
moments and made crossing back out unreliable. The column crossing also
picks which item you land on based on which key crossed: `l` (moving
toward the start) lands on item 0, `h` (moving toward the end) lands on
the last item -- landing on item 0 unconditionally made `h` overshoot
straight past a whole row of items. The row crossing (`j`/`k`, stacked
mode) always lands on item 0 regardless of direction, since a group isn't
a row with a "near" and "far" end the way items in a group are.

Deliberately out of scope: mouse hover does not move the keyboard cursor
(unlike the built-in plugin), so the two coexist without needing to be
unified.

**The `omarchy.network` conflict banner checks, it doesn't assume.**
`Panel.qml` shells out to `omarchy plugin list --json | jq` on every open
(not polled continuously -- this doesn't change while the popup is up) to
read the built-in plugin's actual `enabled`/`canDisable` state, rather than
caching a one-time answer or hardcoding an assumption about a typical
install. `canDisable` gates whether the "Disable it" button even appears --
if a future Omarchy version marks it non-disableable, the fallback text is
still correct. Dismissal ("Keep both") is a marker file
(`~/.config/netctl/hide-network-conflict-notice`), not an in-memory flag,
so choosing to run both is remembered across restarts, not just for one
session.

There's no real conflict for anything either plugin changes on purpose —
route-metric writes, band pinning, DHCP/Static, connect/disconnect — since
all of that goes through `nmcli` against NetworkManager's own state, and
NetworkManager is the single source of truth both plugins just read back;
neither can leave the other showing stale or contradictory state. The one
actual exception is Wi-Fi scanning, controlled by
`WifiDevice.scannerEnabled` — a flag that lives outside NetworkManager
(it's not a connection setting, just an in-memory scan toggle) and is
shared by every plugin that touches it, with no reference counting across
separate plugins. If both popups are open at once, closing one can turn
scanning off for the other too; this is non-critical for a different
reason than everything else above — it self-heals the moment either popup
reopens (which refreshes its own scan state), so at worst you see a stale
nearby-networks list for a moment, not lost or corrupted state. This is
the one exception netctl's banner exists to surface at all.

## What's original vs. adapted from `omarchy.network`

netctl started as a clone of the built-in `omarchy.network` plugin and
diverged substantially. When reviewing a diff near one of these spots, it's
worth knowing which side of that line it's on:

**Lifted essentially unchanged** from the built-in plugin's `Panel.qml`:
- `findDevice(type)` in both `WifiSection.qml` and `EthernetSection.qml` —
  picks the connected device of a given `DeviceType`, else the
  first-enumerated one. This is the reason a second same-type NIC isn't
  handled today (see `DEVELOPMENT.md`).
- The Wi-Fi scan-list per-row action state machine in `WifiScanList.qml`
  (`networkForSsid`, `wifiIndexForSsid`, `runNetworkAction`,
  `clearNetworkAction`, `failNetworkAction`, `checkActionCompletion`) —
  adapted to this component's own state, but the logic and structure are
  the built-in plugin's.

**Ported and then refactored** from the built-in plugin's `Model.js`:
- Throughput-rate delta math (`throughputState`) and ping/packet-loss
  rolling-average math (`pingLatencyState` and friends) — same approach
  and tuned constants (e.g. `pingHistoryWindow: 24`, `pingAverageWindow:
  5`), but pulled out of inline QML into pure `Model.js` functions so each
  `StatsGrid` instance can own an independent per-interface history
  instead of one shared default-route sample.

**Original to netctl**, with no equivalent in the built-in plugin:
- The entire dual-simultaneous-interface architecture described above —
  the built-in plugin is single-interface-at-a-time by design.
- "Set primary" / route-metric pinning in its entirety.
- DHCP/Static IPv4 toggle and saved static-IP profiles (`ProfileList.qml`).
- Ethernet connect/disconnect.
- All of `EthernetSection.qml`'s status-parsing shell script and retry/
  recovery logic.
- The keyboard-navigation architecture (`Panel.qml`'s central cursor
  controller). The built-in plugin also has vim-style navigation, but it's
  one flat `focusSection` state machine over a single network's controls;
  netctl's two independent, side-by-side-or-stacked sections needed a
  different shape (a controller that hands a cursor between two sections
  that stay unaware of each other) rather than anything portable from the
  built-in's model — see "Keyboard navigation" above.
- The `omarchy.network` conflict banner. The built-in plugin has no
  equivalent — it has no reason to check for netctl's existence.

**Delegates to an existing system tool rather than reimplementing it**:
Wi-Fi band selection (`WifiSection.qml`) shells out to
`omarchy-network-band`, the same standalone CLI the built-in plugin's own
band picker uses — neither plugin reimplements the `iw`/`nmcli` band-pinning
logic; this one just polls its status output and forwards clicks to it.

**Framework boilerplate that looks borrowed but isn't**: the
`Panel { moduleName; ipcTarget; manageIpc: false }` root wiring and the
`qs.Ui`/`qs.Commons` component set (`PanelSectionHeader`, `PanelToolTip`,
`BarIconButton`, `IpcHandler`, `KeyboardPanel`, `PanelKeyCatcher`, etc.) are
conventions every Omarchy shell plugin uses, not anything specific to
`omarchy.network`.

## Invariants worth knowing before you change things

- **`hasProfile` is not `isConnected`.** A wired/Wi-Fi profile can exist
  (so `hasProfile` is true) while the interface is disconnected — this is
  intentional (it's how the status line and the DHCP/Static form still
  work while offline), but it means `setRouteMetric()` guards on
  `isConnected` explicitly rather than assuming `hasProfile` implies it's
  live.
- **`primaryCompareMetric` uses `undefined`, not a sentinel number, to mean
  "nothing to compare against."** `Model.isPrimary()` treats a non-finite
  compare value as "I'm primary by default." `Panel.qml` relies on this by
  passing `undefined` (not the sibling's stale last-known metric) whenever
  the sibling isn't actually connected.
- **Only a genuine promotion should tell the sibling to demote.** If a
  demotion also triggered a demote-notify, the sibling's own
  demote-in-response would bounce back and demote the original caller too,
  forever. This is why `metricProc.promoting` gates the
  `routeMetricApplied` signal rather than firing it on every metric write.
- **`actionGeneration` exists to make killed processes' late exits
  harmless.** Any function that can cancel an in-flight `Process`
  (`cancelInFlightApply()`) bumps this counter first; `Process.onExited`
  compares its own captured generation against the current one and ignores
  itself if they don't match. If you add a new cancellable action, wire it
  through this counter too, or a stale exit can silently clobber newer
  state.
- **Static-IP fields are set imperatively, not via a `text:` binding.**
  Typing in a `TextField` permanently severs a declarative binding on that
  property, so `seedStaticFields()` writes `addressInput.text = ...`
  directly. A `text: root.addressField` binding would stop reseeding after
  the user's first keystroke.
- **All ported/original shell scripts pass user-typed values as positional
  args**, never interpolated into the script string — e.g.
  `applyIpv4Script` takes `addr`/`gw`/`dns` as `$3`/`$4`/`$5`. Keep this
  pattern for any new script that touches user input.
- **A `TextField` that becomes invisible does not lose `activeFocus`.** Qt
  Quick only clears focus when something else explicitly claims it — hiding
  the container isn't enough, and a static-IP apply succeeding collapses
  the fields asynchronously (in a `Process.onExited` handler) with nothing
  else ever taking focus back. Any `anyFieldFocused`-style gate must key off
  the form's own open/closed flag (`manualEntryOpen`, `addingProfile`,
  `passwordSsid !== ""`), not the field's raw `.activeFocus` alone —
  otherwise the gate stays stuck true forever on a
  field nobody can see, and every keypress silently types into it instead
  of navigating. `Panel.qml`'s key catcher additionally reclaims focus for
  itself the moment that gate clears, since Qt Quick won't do that either.
