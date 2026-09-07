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
| `Panel.qml` | Bar icon + popup shell; combines both sections, cross-wires primary-route comparison |
| `WifiSection.qml` | Wi-Fi status, radio toggle, primary-route control, nearby-network list |
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
this plugin exists instead of the built-in `omarchy.network` widget (that
widget reports only whichever interface currently owns the default route,
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
naturally isolated per instance. This is what would make a future
`Repeater`-based multi-device version "free" for state management, even
though the route-metric logic above is not free.

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
`navGroupIds` list (e.g. Wi-Fi's `["hero", "band", "list"]`, only present
when actually visible) plus `navGroupCount(id)` / `navActivate(id, item)` /
`navDelete(id, item)` -- and receives `cursorActive`/`cursorGroup`/
`cursorItem` back as plain input properties, with `cursorGroup` arriving as
`-1` whenever the cursor actually belongs to the other section. Every
control's own `hasCursor` binding is then just
`cursorActive && cursorGroup === groupIndex("id") && cursorItem === N`.
Neither section imports or references the other; `Panel.qml`'s
`moveCursor(dx, dy)` is the only code that hands the cursor from one
section's edge to the other's, and it does so differently depending on
`panel.twoColumn`: `j`/`k` spill into the other section only while stacked
(single column), `h`/`l` spill into the other section only while side by
side -- see its own comment for the exact direction rules. Deliberately
out of scope: mouse hover does not move the keyboard cursor (unlike the
built-in widget), so the two coexist without needing to be unified.

## What's original vs. adapted from `omarchy.network`

netctl started as a clone of the built-in `omarchy.network` widget and
diverged substantially. When reviewing a diff near one of these spots, it's
worth knowing which side of that line it's on:

**Lifted essentially unchanged** from the built-in widget's `Panel.qml`:
- `findDevice(type)` in both `WifiSection.qml` and `EthernetSection.qml` —
  picks the connected device of a given `DeviceType`, else the
  first-enumerated one. This is the reason a second same-type NIC isn't
  handled today (see `DEVELOPMENT.md`).
- The Wi-Fi scan-list per-row action state machine in `WifiScanList.qml`
  (`networkForSsid`, `wifiIndexForSsid`, `runNetworkAction`,
  `clearNetworkAction`, `failNetworkAction`, `checkActionCompletion`) —
  adapted to this component's own state, but the logic and structure are
  the built-in widget's.

**Ported and then refactored** from the built-in widget's `Model.js`:
- Throughput-rate delta math (`throughputState`) and ping/packet-loss
  rolling-average math (`pingLatencyState` and friends) — same approach
  and tuned constants (e.g. `pingHistoryWindow: 24`, `pingAverageWindow:
  5`), but pulled out of inline QML into pure `Model.js` functions so each
  `StatsGrid` instance can own an independent per-interface history
  instead of one shared default-route sample.

**Original to netctl**, with no equivalent in the built-in widget:
- The entire dual-simultaneous-interface architecture described above —
  the built-in widget is single-interface-at-a-time by design.
- "Set primary" / route-metric pinning in its entirety.
- DHCP/Static IPv4 toggle and saved static-IP profiles (`ProfileList.qml`).
- Ethernet connect/disconnect.
- All of `EthernetSection.qml`'s status-parsing shell script and retry/
  recovery logic.

**Framework boilerplate that looks borrowed but isn't**: the
`Panel { moduleName; ipcTarget; manageIpc: false }` root wiring and the
`qs.Ui`/`qs.Commons` component set (`PanelSectionHeader`, `PanelToolTip`,
`BarIconButton`, `IpcHandler`, `KeyboardPanel`, etc.) are conventions every
Omarchy shell plugin uses, not anything specific to `omarchy.network`.

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
