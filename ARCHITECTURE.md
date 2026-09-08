# Architecture

Orientation for anyone reviewing or extending this codebase — how it's put
together, what's original vs. adapted from elsewhere, and the non-obvious
invariants worth knowing before touching a given file. For end-user docs
see `README.md`; for the dev loop and forward-looking notes see
`DEVELOPMENT.md`.

## Repo layout

| File | Responsibility |
|---|---|
| `manifest.json` | Plugin manifest (id `simulnetdevice`, bar-widget) |
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
own interface (`ip`/`nmcli ... dev $iface`). `Panel.qml` is a thin shell:
it instantiates one of each section, lays them out in a `Grid` (1 or 2
columns depending on `twoColumn`), and picks the bar icon.

**"Set primary" is pairwise by construction.** There is no shared
route-metric coordinator. Each section exposes `routeMetric`, `isPrimary`
(compared against `primaryCompareMetric`), `setRouteMetric()`, and a
`routeMetricApplied` signal. `Panel.qml` wires the two sections together
directly: each one's `primaryCompareMetric` is bound to the other's live
`routeMetric`, and each one's `onRouteMetricApplied` calls
`setRouteMetric(SECONDARY_METRIC)` on the other, by id. This does not
generalize to more than two interfaces without a rewrite (see
`DEVELOPMENT.md`'s multi-NIC notes).

**Per-instance state, not singletons.** Each section is a normal QML
component instance rather than a global/singleton, so its `info`,
`actionProc`, retry/recovery timers, and `actionGeneration` counter are
isolated per instance, with nothing shared across sections.

**`Model.js` holds all the pure logic.** Parsing (`parseKeyValue`),
formatting, validation, and the throughput/ping/route-metric/profile math
all live here with no QML/Quickshell imports, so they're runnable and
testable under plain `node`. QML files call into `Model.js` rather than
reimplementing this logic inline.

**Keyboard navigation is a central controller over two sections.**
`Panel.qml` owns the cursor state (`cursorSection`, `cursorGroup`,
`cursorItem`). Each section exposes `navGroupIds`, `navGroupCount(id)`,
`navActivate(id, item)`, `navDelete(id, item)`, and receives
`cursorActive`/`cursorGroup`/`cursorItem` back as input properties, with
`cursorGroup` arriving as `-1` whenever the cursor belongs to the other
section. Each section computes its own `currentGroupId` (the group name
the cursor is on, or `""`), so every control's `hasCursor` binding is
`currentGroupId === "id" && cursorItem === N`. Neither section imports or
references the other.

Groups are vertically-stacked content, navigated with `j`/`k`; items within
a group are horizontally-adjacent controls, navigated with `h`/`l`. The
nearby-network list (`WifiSection.qml`) and the saved-profile list
(`EthernetSection.qml`) each generate one group per row (`"network-0"`,
`"network-1"`, ... and `"profile-0"`, `"profile-1"`, ...).

`Panel.qml`'s `moveCursor(dx, dy)` hands the cursor between sections,
depending on `panel.twoColumn`: `j`/`k` spill into the other section only
while stacked (single column), landing on that section's first group when
moving down or its last group when moving up. `h`/`l` spill into the other
column only while side by side, landing on a group with the same id if the
destination section has one, else on "hero"; `l` lands on item 0 of the
destination group, `h` on its last item. The row crossing (`j`/`k`,
stacked mode) always lands on item 0.

Mouse hover does not move the keyboard cursor.

**Two self-recovery mechanisms exist beyond passive status reporting.**

1. *Sustained ping-loss recovery.* `StatsGrid.qml` emits
   `sustainedPacketLoss()` when `Model.isSustainedPingLoss()` sees the
   most recent 5 samples (~15s) all lost. `WifiSection.qml` responds with
   a radio off → 1.5s → on cycle; `EthernetSection.qml` responds with a
   disconnect → reconnect chain through the section's existing
   `actionProc`/`pendingAction` machinery (`recoveryPhase`: `"" |
   "disconnecting" | "connecting"`). Both sides guard against
   re-triggering mid-recovery and enforce a cooldown after any attempt.
2. *Ethernet apply retry.* When an Apply/DHCP/Static action fails,
   `EthernetSection.qml` distinguishes two causes: no cable sets
   `retryActionOnCarrier` and waits for `hasCable` to flip true before
   retrying once; cable already present gets a bounded retry
   (`maxApplyRetries`: 3, on a 2-second `applyRetryTimer`) before falling
   through to an error. `cancelInFlightApply()` lets a fresh explicit
   click pre-empt whichever of these is mid-flight.

See `DEVELOPMENT.md` for the testing status of both mechanisms.

**The `omarchy.network` conflict banner checks live state on each open.**
`Panel.qml` shells out to `omarchy plugin list --json | jq` every time the
popup opens to read the built-in plugin's `enabled`/`canDisable` state.
`canDisable` gates whether the "Disable it" button appears. Dismissal
("Keep both") is a marker file
(`~/.config/simulnetdevice/hide-network-conflict-notice`), not an
in-memory flag.

Route-metric writes, band pinning, DHCP/Static, and connect/disconnect all
go through `nmcli` against NetworkManager's own state, so neither plugin
can leave the other showing stale state. The one shared flag is Wi-Fi
scanning (`WifiDevice.scannerEnabled`), which lives outside NetworkManager
with no reference counting across plugins — if both popups are open,
closing one can turn scanning off for the other until it's reopened.

## What's original vs. adapted from `omarchy.network`

SimulNetDevice started as a clone of the built-in `omarchy.network` plugin and
diverged substantially. When reviewing a diff near one of these spots, it's
worth knowing which side of that line it's on:

**Lifted essentially unchanged** from the built-in plugin's `Panel.qml`:
- `findDevice(type)` in both `WifiSection.qml` and `EthernetSection.qml` —
  picks the connected device of a given `DeviceType`, else the
  first-enumerated one (see `DEVELOPMENT.md`'s multi-NIC notes).
- The Wi-Fi scan-list per-row action state machine in `WifiScanList.qml`
  (`networkForSsid`, `wifiIndexForSsid`, `runNetworkAction`,
  `clearNetworkAction`, `failNetworkAction`, `checkActionCompletion`).

**Ported and then refactored** from the built-in plugin's `Model.js`:
- Throughput-rate delta math (`throughputState`) and ping/packet-loss
  rolling-average math (`pingLatencyState` and friends), pulled out of
  inline QML into pure `Model.js` functions, one independent history per
  `StatsGrid` instance.

**Original to SimulNetDevice**, with no equivalent in the built-in plugin:
- The entire dual-simultaneous-interface architecture described above —
  the built-in plugin is single-interface-at-a-time by design.
- "Set primary" / route-metric pinning in its entirety.
- DHCP/Static IPv4 toggle and saved static-IP profiles (`ProfileList.qml`).
- Ethernet connect/disconnect.
- All of `EthernetSection.qml`'s status-parsing shell script, and both
  self-recovery mechanisms (Wi-Fi's radio-cycle and Ethernet's
  disconnect/reconnect on sustained ping loss, plus Ethernet's apply
  retry) -- see "Two self-recovery mechanisms" above.
- The keyboard-navigation architecture (`Panel.qml`'s central cursor
  controller). The built-in plugin has a flat `focusSection` state machine
  over a single network's controls instead — see "Keyboard navigation"
  above.
- The `omarchy.network` conflict banner. The built-in plugin has no
  equivalent.

**Delegates to an existing system tool rather than reimplementing it**:
Wi-Fi band selection (`WifiSection.qml`) shells out to
`omarchy-network-band`, the same CLI the built-in plugin's own band picker
uses, polling its status output and forwarding clicks to it.

**Framework boilerplate that looks borrowed but isn't**: the
`Panel { moduleName; ipcTarget; manageIpc: false }` root wiring and the
`qs.Ui`/`qs.Commons` component set (`PanelSectionHeader`, `PanelToolTip`,
`BarIconButton`, `IpcHandler`, `KeyboardPanel`, `PanelKeyCatcher`, etc.) are
conventions every Omarchy shell plugin uses, not anything specific to
`omarchy.network`.

## Invariants worth knowing before you change things

- **`hasProfile` is not `isConnected`.** A profile can exist while the
  interface is disconnected; `setRouteMetric()` guards on `isConnected`
  explicitly rather than assuming `hasProfile` implies it's live.
- **`primaryCompareMetric` uses `undefined`, not a sentinel number, for
  "nothing to compare against."** `Model.isPrimary()` treats a non-finite
  compare value as primary-by-default. `Panel.qml` passes `undefined`
  (not the sibling's stale last-known metric) whenever the sibling isn't
  connected.
- **`routeMetricApplied` fires only on a genuine promotion, not a
  demotion**, gated by `metricProc.promoting`.
- **`actionGeneration` is bumped before cancelling an in-flight
  `Process`.** `cancelInFlightApply()` bumps it first; `Process.onExited`
  compares its own captured generation against the current one and ignores
  itself on a mismatch. A new cancellable action needs to wire through
  this counter too.
- **`staticPanelOpen` and `manualEntryOpen` are two separate disclosure
  states.** Clicking "Static" toggles `staticPanelOpen`, revealing the
  saved-profiles list (`ProfileList.qml`); the panel closes on a second
  click or the popup closing. `manualEntryOpen` is nested inside that,
  behind its own "Enter manually…" button.
- **The nearby-network list is a `ListView`, not a `Repeater`**, capped at
  `visibleRowCount` rows (`WifiScanList.qml`), scrolling for the rest.
- **Static-IP fields are set imperatively, not via a `text:` binding**
  (`seedStaticFields()` writes `addressInput.text = ...` directly).
- **All ported/original shell scripts pass user-typed values as positional
  args**, never interpolated into the script string — e.g.
  `applyIpv4Script` takes `addr`/`gw`/`dns` as `$3`/`$4`/`$5`.
- **A `TextField` that becomes invisible does not lose `activeFocus`.**
  `anyFieldFocused`-style gates key off the form's own open/closed flag
  (`manualEntryOpen`, `addingProfile`, `passwordSsid !== ""`), not the
  field's raw `.activeFocus` alone. `Panel.qml`'s key catcher reclaims
  focus for itself the moment that gate clears.
