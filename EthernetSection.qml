import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import Quickshell.Networking
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Ethernet status + connect/disconnect + DHCP/static IPv4, scoped directly
// to the wired interface (`ip`/`nmcli ... dev $iface`) rather than the
// default route, so it stays accurate no matter which interface currently
// carries traffic. Embedded as content inside Panel.qml's popup -- this
// component owns no window/bar-icon chrome of its own.
Item {
  id: root

  required property QtObject bar
  // Whether the owning popup is open. Ping sampling (the only "noisy" part
  // of the status script) only runs while true; carrier/IP/route polling
  // for the bar icon and connect switch keeps running regardless.
  property bool opened: false

  // ---------- Keyboard cursor ----------
  // See WifiSection's identical comment -- driven from Panel.qml's central
  // cursor controller, -1 whenever the cursor is actually WifiSection's.
  property bool cursorActive: false
  property int cursorGroup: -1
  property int cursorItem: -1

  // Groups, top to bottom: the hero row, the DHCP/Static toggle (only once
  // there's a profile to configure), then -- only while the Static fields
  // are actually open -- one group per saved-profile row (each with its own
  // Apply/Delete, so h/l moves within a row and j/k moves between rows,
  // matching how they're actually laid out), then "Save current as…", then
  // "Enter manually" (only while it isn't already open).
  readonly property var navGroupIds: {
    var ids = ["hero"]
    if (root.hasProfile) ids.push("mode")
    if (root.hasProfile && root.staticPanelOpen) {
      var profiles = profileList.profiles || []
      for (var i = 0; i < profiles.length; i++) ids.push("profile-" + i)
      ids.push("add-profile")
      if (!root.manualEntryOpen) ids.push("manual-toggle")
    }
    return ids
  }
  // The group id the cursor is actually on, or "" -- every hasCursor
  // binding below is just `currentGroupId === "id" && cursorItem === N`.
  readonly property string currentGroupId: (root.cursorActive && root.cursorGroup >= 0 && root.cursorGroup < root.navGroupIds.length)
    ? root.navGroupIds[root.cursorGroup] : ""

  function navGroupCount(id) {
    if (id === "hero") return root.isConnected ? 2 : 1
    if (id === "mode") return 2
    if (id.indexOf("profile-") === 0) return 2 // Apply, Delete
    if (id === "add-profile") return 1
    if (id === "manual-toggle") return 1
    return 0
  }

  function navActivate(id, item) {
    if (id === "hero") {
      if (root.isConnected) {
        if (item === 0) { if (!root.isPrimary) root.setRouteMetric(Model.PRIMARY_METRIC); return }
        if (item === 1) { if (root.hasProfile && root.hasCable) root.disconnectEthernet(); return }
      } else if (item === 0) {
        if (root.hasProfile && root.hasCable) root.connectEthernet()
      }
      return
    }
    if (id === "mode") { root.selectMode(item === 0 ? "auto" : "manual"); return }
    if (id.indexOf("profile-") === 0) {
      var idx = parseInt(id.substring(8), 10)
      if (item === 0) profileList.applyByIndex(idx)
      else profileList.deleteByIndex(idx)
      return
    }
    if (id === "add-profile") { profileList.startAdding(); return }
    if (id === "manual-toggle") { root.manualEntryOpen = true; return }
  }

  function navDelete(id, item) {
    if (id.indexOf("profile-") === 0) profileList.deleteByIndex(parseInt(id.substring(8), 10))
  }

  readonly property var networkDevices: Networking.devices ? Networking.devices.values : []
  readonly property var wiredDevice: findDevice(DeviceType.Wired)
  readonly property string iface: wiredDevice ? wiredDevice.name : ""

  // Picks the connected device of this type, else the first-enumerated one.
  // Lifted from the built-in omarchy.network widget's Panel.qml (same
  // function, unchanged) -- see README's Known limitations for what this
  // means on a box with two wired NICs (onboard + dock, say).
  function findDevice(type) {
    var devices = networkDevices || []
    var fallback = null
    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      if (!device || device.type !== type) continue
      if (device.connected) return device
      if (!fallback) fallback = device
    }
    return fallback
  }

  property var info: ({})
  readonly property string linkState: Model.linkState(info)
  readonly property bool hasAdapter: linkState !== "no-device"
  readonly property bool hasCable: linkState !== "no-device" && linkState !== "no-cable"
  readonly property bool isConnected: linkState === "connected"
  readonly property bool hasProfile: !!info.connection

  readonly property string statusLine: Model.statusText(linkState)
  readonly property string speedLabel: Model.formatSpeed(info.speed)

  // Which saved profile (if any) matches the currently-applied static
  // config, surfaced in the hero so it's visible without expanding the
  // IPv4 section at all.
  function findCurrentProfileName() {
    if (formMode !== "manual") return ""
    var profiles = profileList.profiles || []
    for (var i = 0; i < profiles.length; i++) {
      var p = profiles[i]
      if (p && (p.address || "") === addressField && (p.gateway || "") === gatewayField) return p.name || ""
    }
    return ""
  }
  readonly property string currentProfileName: findCurrentProfileName()

  readonly property string icon: "󰈀"
  readonly property real iconOpacity: {
    if (linkState === "connected") return 1.0
    if (linkState === "connecting") return 0.75
    return 0.4
  }

  // Public interface for Panel.qml's primary-route coordination.
  function connectionName() { return info.connection || "" }
  readonly property int routeMetric: parseInt(info.route_metric, 10)
  readonly property bool isPrimary: Model.isPrimary(info.route_metric, primaryCompareMetric)
  // Panel.qml sets this to the sibling section's current metric so the
  // "Primary" pill reflects the real comparison, not a fixed threshold.
  property var primaryCompareMetric: undefined
  // A metric change on its own only updates the saved profile -- it doesn't
  // retroactively touch the kernel's live routing table for an already-
  // active connection, so `connection up` has to follow the modify (same
  // two-step sequence already validated live: modify, then reactivate).
  readonly property string setMetricScript:
    "conn=$1; metric=$2\n" +
    "nmcli connection modify \"$conn\" ipv4.route-metric \"$metric\" || exit 1\n" +
    "nmcli connection up \"$conn\" >/dev/null 2>&1 || true\n"

  function setRouteMetric(metric) {
    if (!hasProfile) return
    // hasProfile alone doesn't mean "currently connected" -- the status
    // script names a saved profile as a fallback even while disconnected --
    // so without this, the sibling's demote-to-secondary cross-wire (see
    // Panel.qml) would force `connection up` on an interface the user just
    // explicitly disabled, silently turning it back on.
    if (!isConnected) return
    var promoting = metric === Model.PRIMARY_METRIC
    // Even when connected, skip the actual modify+up round-trip if the
    // metric is already what's being asked for: `connection up` forces a
    // real reactivation (a genuine Wi-Fi disconnect/reconnect blip on that
    // side, confirmed live), which every unrelated "Set primary" click on
    // the sibling would otherwise trigger for no actual change. But a
    // genuine "make me primary" click still has to tell the sibling to
    // demote even when *my* metric already happens to be right -- otherwise
    // two connections that both ended up at the same metric (a leftover
    // from an earlier bug) can never be untied, since neither side's click
    // would ever have anything of its own left to change.
    if (parseInt(metric, 10) === routeMetric) {
      if (promoting) root.routeMetricApplied()
      return
    }
    metricProc.command = ["bash", "-c", setMetricScript, "ethernet-metric", info.connection, String(metric)]
    // See WifiSection's identical comment: only a genuine promotion should
    // notify the sibling to demote, or the sibling's own demote-in-response
    // bounces back and demotes us too, forever.
    metricProc.promoting = promoting
    metricProc.running = true
  }
  signal routeMetricApplied()

  Process {
    id: metricProc
    property bool promoting: false
    onExited: function(exitCode) {
      root.refresh()
      if (promoting) root.routeMetricApplied()
    }
  }

  implicitWidth: column.implicitWidth
  implicitHeight: column.implicitHeight

  // Local form state for the DHCP/Static choice. Kept separate from the
  // profile's real `ipv4.method` so clicking "Static" just opens the form —
  // nothing is written until Apply. Synced back to the real method below
  // whenever a refresh lands and nothing is mid-flight.
  property string formMode: "auto"  // "auto" | "manual"
  property string addressField: ""
  property string gatewayField: ""
  property string dnsField: ""
  property string pendingAction: ""  // "connect" | "disconnect" | "apply-dhcp" | "apply-static"
  readonly property bool busy: pendingAction !== ""
  property string lastError: ""
  // Set when an apply fails specifically because there's no carrier (e.g.
  // clicked Apply/DHCP before actually plugging the cable in) -- there's no
  // active connection for NetworkManager to retry on its own once the cable
  // does go live, so this plugin has to notice and redo the same apply
  // itself (see onHasCableChanged below).
  property string retryActionOnCarrier: ""  // "" | "apply-dhcp" | "apply-static"

  readonly property bool canApply: Model.canApplyStatic({ address: addressField, gateway: gatewayField })

  // Fields are set imperatively (not via a `text: root.addressField`
  // binding) because typing in a TextField severs a declarative binding on
  // that property for good -- these fields persist for the panel's whole
  // lifetime, so a broken binding would silently stop reseeding after the
  // user's first keystroke.
  function seedStaticFields() {
    var seed = Model.staticFormDefaults(info)
    addressField = seed.address
    gatewayField = seed.gateway
    dnsField = seed.dns
    addressInput.text = seed.address
    gatewayInput.text = seed.gateway
    dnsInput.text = seed.dns
  }

  // Called from ProfileList: fills the form from a saved profile AND
  // applies it immediately -- with a saved profile on hand there's no
  // reason to make the user open the raw fields and press Apply again just
  // to reapply something already known-good. Manual entry stays reserved
  // for actually typing or editing values (see manualEntryOpen below).
  function applyProfileToForm(profile) {
    if (formMode !== "manual") selectMode("manual")
    addressField = profile.address || ""
    gatewayField = profile.gateway || ""
    dnsField = profile.dns || ""
    addressInput.text = addressField
    gatewayInput.text = gatewayField
    dnsInput.text = dnsField
    applyStatic()
  }

  // Two independent disclosures: the static fields area (ProfileList + the
  // raw manual-entry fields), opened by clicking "Static" and closed by
  // clicking "Static" again or by the whole panel closing -- and, nested
  // inside that, the raw address/gateway/DNS fields themselves, only
  // needed to type a new config or edit an existing one (applying a saved
  // profile never needs them open).
  property bool staticPanelOpen: false
  property bool manualEntryOpen: false
  // Same auto-focus pattern as ProfileList's name field and the Wi-Fi
  // password field -- gives keyboard nav somewhere to land the moment the
  // fields appear, instead of a dead end below "Enter manually" with no
  // way to actually reach them.
  onManualEntryOpenChanged: if (manualEntryOpen) Qt.callLater(function() { addressInput.forceActiveFocus() })

  // A click here is the user changing their mind -- it should always win,
  // even over an apply that's still working through its retries (e.g. a
  // DHCP apply on a network with no DHCP server at all keeps retrying and
  // sitting "busy" for as long as NetworkManager's own DHCP timeout takes
  // per attempt, which is long enough that every button, including this
  // one, would otherwise stay frozen for minutes -- confirmed live).
  function selectMode(mode) {
    if (busy) cancelInFlightApply()
    if (mode === "auto") {
      formMode = "auto"
      manualEntryOpen = false
      staticPanelOpen = false
      applyDhcp()
      return
    }
    // Second click on "Static" while the fields are already open: just
    // close them back up. Only actually switch away from "manual" if
    // nothing static is really applied -- if a static profile IS live,
    // the Static button should stay the selected one even with the
    // fields tucked away.
    if (staticPanelOpen) {
      staticPanelOpen = false
      manualEntryOpen = false
      if (!Model.isManualMethod(info.method)) formMode = "auto"
      return
    }
    if (formMode !== "manual") seedStaticFields()
    formMode = "manual"
    staticPanelOpen = true
  }

  // Stops whatever actionProc/retry/recovery cycle is in flight so a fresh
  // explicit click (selectMode, applyDhcp, applyStatic) can proceed right
  // away instead of being silently swallowed by the busy guard.
  function cancelInFlightApply() {
    applyRetryTimer.stop()
    retryActionOnCarrier = ""
    applyRetriesLeft = 0
    recoveryPhase = ""
    recovering = false
    // Bump first: if actionProc is genuinely running and gets killed below,
    // its eventual (delayed) exit will carry the old dispatchGeneration and
    // onExited will just ignore it instead of acting on now-stale state.
    actionGeneration += 1
    if (actionProc.running) actionProc.running = false
    pendingAction = ""
    lastError = ""
  }

  // Only ever syncs FROM the live profile INTO "manual" (to reflect a
  // static config that's actually applied). Never forces "manual" back to
  // "auto" on its own -- the live method stays "auto" the whole time the
  // user is filling in a new static config (nothing is written until
  // Apply), and this function runs on every 3s poll via onInfoChanged, so
  // doing that used to blow away the open form and whatever the user had
  // typed before they could hit Apply.
  function syncFormMode() {
    if (busy) return
    var manual = Model.isManualMethod(info.method)
    if (manual) {
      if (formMode !== "manual") seedStaticFields()
      formMode = "manual"
    } else if (formMode !== "manual") {
      formMode = "auto"
    }
  }

  onInfoChanged: syncFormMode()

  // Bumped by cancelInFlightApply() and every dispatch below -- lets
  // actionProc.onExited recognize and ignore the delayed exit of a process
  // that was killed out from under it, rather than acting on stale state
  // (see cancelInFlightApply's comment).
  property int actionGeneration: 0

  function connectEthernet() {
    if (busy || !hasProfile) return
    retryActionOnCarrier = ""
    pendingAction = "connect"
    lastError = ""
    actionGeneration += 1
    actionProc.dispatchGeneration = actionGeneration
    actionProc.command = ["nmcli", "connection", "up", info.connection]
    actionProc.running = true
  }

  function disconnectEthernet() {
    if (busy || !iface) return
    retryActionOnCarrier = ""
    pendingAction = "disconnect"
    lastError = ""
    actionGeneration += 1
    actionProc.dispatchGeneration = actionGeneration
    actionProc.command = ["nmcli", "device", "disconnect", iface]
    actionProc.running = true
  }

  // See WifiSection's identical comment on the same real, confirmed-live
  // condition. Ethernet's equivalent of "radio off/on" is a disconnect
  // followed by a reconnect (recoveryPhase tracks which half is in
  // flight, chained together in actionProc.onExited below since
  // connectEthernet() can't run until disconnectEthernet()'s own
  // pendingAction has actually cleared).
  property bool recovering: false
  property bool recoveryOnCooldown: false
  property string recoveryPhase: ""  // "" | "disconnecting" | "connecting"
  function recoverConnection() {
    if (recovering || recoveryOnCooldown || busy || !isConnected) return
    recovering = true
    recoveryPhase = "disconnecting"
    disconnectEthernet()
  }

  Timer {
    id: recoveryCooldownTimer
    interval: 30000
    repeat: false
    onTriggered: root.recoveryOnCooldown = false
  }

  // IPv4 only, and args are passed positionally rather than interpolated
  // into the script string -- user-typed IP/gateway/DNS values never touch
  // shell parsing.
  // A plain `nmcli connection up` on an already-active profile doesn't
  // reliably force a fresh DHCP negotiation when switching off a static
  // config -- NetworkManager can treat it as a no-op reapply and leave the
  // interface sitting disconnected. Cycling down first forces a real
  // reactivation, and the final `up`'s exit code is no longer swallowed
  // with `|| true`, so a genuine reconnect failure surfaces as an error
  // instead of silently reporting success.
  readonly property string applyIpv4Script:
    "mode=$1; conn=$2; addr=$3; gw=$4; dns=$5\n" +
    "if [[ -z $conn ]]; then echo 'No connection profile' >&2; exit 1; fi\n" +
    "if [[ $mode == static ]]; then\n" +
    "  nmcli connection modify \"$conn\" ipv4.method manual ipv4.addresses \"$addr\" ipv4.gateway \"$gw\" ipv4.dns \"$dns\" ipv4.ignore-auto-dns yes || exit 1\n" +
    "else\n" +
    "  nmcli connection modify \"$conn\" ipv4.method auto ipv4.addresses '' ipv4.gateway '' ipv4.dns '' ipv4.ignore-auto-dns no || exit 1\n" +
    "fi\n" +
    "nmcli connection down \"$conn\" >/dev/null 2>&1 || true\n" +
    "nmcli connection up \"$conn\" || exit 1\n"

  function applyDhcp() {
    if (!hasProfile) return
    if (busy) cancelInFlightApply()
    retryActionOnCarrier = ""
    applyRetriesLeft = maxApplyRetries
    pendingAction = "apply-dhcp"
    lastError = ""
    actionGeneration += 1
    actionProc.dispatchGeneration = actionGeneration
    actionProc.command = ["bash", "-c", applyIpv4Script, "ethernet-ipv4", "dhcp", info.connection, "", "", ""]
    actionProc.running = true
  }

  function applyStatic() {
    if (!hasProfile || !canApply) return
    if (busy) cancelInFlightApply()
    retryActionOnCarrier = ""
    applyRetriesLeft = maxApplyRetries
    pendingAction = "apply-static"
    lastError = ""
    var dns = Model.normalizeDns(dnsField)
    actionGeneration += 1
    actionProc.dispatchGeneration = actionGeneration
    actionProc.command = ["bash", "-c", applyIpv4Script, "ethernet-ipv4", "static", info.connection, addressField, gatewayField, dns]
    actionProc.running = true
  }

  // If the cable actually goes live after a failed apply-dhcp/apply-static
  // (see actionProc.onExited below), redo the same apply automatically --
  // NetworkManager has nothing active to retry on its own here, since the
  // failed `connection up` never got as far as creating one.
  onHasCableChanged: {
    if (!hasCable || retryActionOnCarrier === "") return
    var action = retryActionOnCarrier
    retryActionOnCarrier = ""
    if (action === "apply-static") applyStatic()
    else if (action === "apply-dhcp") applyDhcp()
  }

  // Separate from the carrier-watch retry above: confirmed live that even
  // with the cable *already* connected, a failed apply-dhcp/apply-static
  // can keep failing for a few seconds afterward (NetworkManager settling
  // from the previous failed activation, not something instant-retry fixes
  // but also not something worth making the user click Apply repeatedly
  // for). actionProc.command is left untouched between attempts, so this
  // just re-fires the exact same command.
  readonly property int maxApplyRetries: 3
  property int applyRetriesLeft: 0
  Timer {
    id: applyRetryTimer
    interval: 2000
    repeat: false
    onTriggered: actionProc.running = true
  }

  Process {
    id: actionProc
    property int dispatchGeneration: 0
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      // A process killed by cancelInFlightApply() still exits (delayed);
      // its dispatchGeneration is now behind root.actionGeneration, so
      // this is stale -- something newer already took over, ignore it.
      if (dispatchGeneration !== root.actionGeneration) return
      var isApplyAction = root.pendingAction === "apply-dhcp" || root.pendingAction === "apply-static"
      if (exitCode !== 0 && isApplyAction && !root.hasCable) {
        // Genuinely no cable -- don't spend the bounded retry budget on
        // this, wait for onHasCableChanged instead, which can wait as long
        // as it actually takes to plug the cable in.
        root.retryActionOnCarrier = root.pendingAction
        root.pendingAction = ""
        root.refresh()
        return
      }
      if (exitCode !== 0 && isApplyAction && root.applyRetriesLeft > 0) {
        root.applyRetriesLeft -= 1
        applyRetryTimer.start()
        return
      }
      if (root.pendingAction === "disconnect" && root.recoveryPhase === "disconnecting") {
        if (exitCode === 0) {
          root.recoveryPhase = "connecting"
          root.pendingAction = ""
          root.refresh()
          Qt.callLater(function() { root.connectEthernet() })
          return
        }
        // The disconnect half itself failed -- don't leave recovery wedged
        // on forever, clear it here too (connect's own completion is what
        // clears it on the normal path, but that never runs if we don't
        // even get that far).
        root.recoveryPhase = ""
        root.recovering = false
        root.recoveryOnCooldown = true
        recoveryCooldownTimer.start()
      }
      if (root.pendingAction === "connect" && root.recoveryPhase === "connecting") {
        root.recoveryPhase = ""
        root.recovering = false
        root.recoveryOnCooldown = true
        recoveryCooldownTimer.start()
      }
      if (exitCode !== 0) {
        root.lastError = String(actionStderr.text || actionStdout.text || "Command failed").trim()
      } else if (root.pendingAction === "apply-static") {
        // A successful manual apply is done with the raw fields -- collapse
        // them back like a saved-profile apply never needed to open them.
        // Left open on failure so the values are still there to fix and retry.
        root.manualEntryOpen = false
      }
      root.pendingAction = ""
      root.refresh()
    }
  }

  // `pingArg` gates the one network probe in here (a single 1s-timeout ping
  // to 1.1.1.1) behind whether the popup is actually open, so this doesn't
  // send background pings forever just to keep a closed bar icon updated.
  // Everything else (carrier/ip/route/nmcli reads) is free, so it always runs.
  readonly property string statusScript:
    "iface=$1; do_ping=$2\n" +
    "if [[ -z $iface || ! -e /sys/class/net/$iface ]]; then printf 'state\\tno-device\\n'; exit 0; fi\n" +
    "carrier=$(cat \"/sys/class/net/$iface/carrier\" 2>/dev/null)\n" +
    "speed=$(cat \"/sys/class/net/$iface/speed\" 2>/dev/null)\n" +
    "addr_json=$(ip -4 -j addr show dev \"$iface\" 2>/dev/null)\n" +
    // A profile can carry a leftover static ipv4.addresses entry that NM
    // applies as a *secondary* address even under ipv4.method=auto, so the
    // interface can hold more than one inet address at once. Prefer the one
    // `ip` flags `dynamic` (the actual DHCP lease) over just taking whichever
    // address happens to be listed first.
    "read -r ip prefix <<<\"$(printf '%s' \"$addr_json\" | jq -r '\n" +
    "  .[0].addr_info as $a\n" +
    "  | ([$a[] | select(.family==\"inet\" and (.dynamic // false))] + [$a[] | select(.family==\"inet\")])\n" +
    "  | .[0]\n" +
    "  | if . then \"\\(.local) \\(.prefixlen)\" else \"\" end\n" +
    "' 2>/dev/null)\"\n" +
    "gateway=$(ip -4 route show dev \"$iface\" 2>/dev/null | awk '/^default/ { print $3; exit }')\n" +
    "conn=$(nmcli -t -f GENERAL.CONNECTION dev show \"$iface\" 2>/dev/null | cut -d: -f2-)\n" +
    "nmstate=$(nmcli -t -f GENERAL.STATE dev show \"$iface\" 2>/dev/null | cut -d: -f2-)\n" +
    "if [[ -z $conn || $conn == '--' ]]; then\n" +
    "  conn=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2 == \"802-3-ethernet\" { print $1; exit }')\n" +
    "fi\n" +
    "printf 'iface\\t%s\\n' \"$iface\"\n" +
    "printf 'carrier\\t%s\\n' \"${carrier:-0}\"\n" +
    "printf 'speed\\t%s\\n' \"${speed:-}\"\n" +
    "printf 'ip\\t%s\\n' \"${ip:-}\"\n" +
    "printf 'prefix\\t%s\\n' \"${prefix:-}\"\n" +
    "printf 'gateway\\t%s\\n' \"${gateway:-}\"\n" +
    "printf 'nmstate\\t%s\\n' \"${nmstate:-}\"\n" +
    "if [[ -r /sys/class/net/$iface/statistics/rx_bytes ]]; then printf 'rx_bytes\\t%s\\n' \"$(cat /sys/class/net/$iface/statistics/rx_bytes)\"; fi\n" +
    "if [[ -r /sys/class/net/$iface/statistics/tx_bytes ]]; then printf 'tx_bytes\\t%s\\n' \"$(cat /sys/class/net/$iface/statistics/tx_bytes)\"; fi\n" +
    "if [[ $do_ping == 1 ]]; then\n" +
    // -I $iface, not a bare ping to 1.1.1.1: without it this measures
    // whichever interface currently owns the default route, not this one --
    // so flipping "Set primary" or disabling the *other* interface would
    // show packet loss on this row too, even though this interface's own
    // path never had a problem.
    "  ms=$(LC_ALL=C ping -n -c1 -W1 -I \"$iface\" 1.1.1.1 2>/dev/null | awk -F'time[=<]' '/time[=<]/ { split($2, p, \" \"); print p[1]; exit }')\n" +
    "  printf 'internet_ping_ms\\t%s\\n' \"${ms:-}\"\n" +
    "fi\n" +
    "if [[ -n $conn ]]; then\n" +
    "  printf 'connection\\t%s\\n' \"$conn\"\n" +
    "  method=$(nmcli -g ipv4.method connection show \"$conn\" 2>/dev/null)\n" +
    "  cfg_addr=$(nmcli -g ipv4.addresses connection show \"$conn\" 2>/dev/null)\n" +
    "  cfg_gw=$(nmcli -g ipv4.gateway connection show \"$conn\" 2>/dev/null)\n" +
    "  cfg_dns=$(nmcli -g ipv4.dns connection show \"$conn\" 2>/dev/null)\n" +
    "  route_metric=$(nmcli -g ipv4.route-metric connection show \"$conn\" 2>/dev/null)\n" +
    "  printf 'method\\t%s\\n' \"${method:-auto}\"\n" +
    "  printf 'cfg_address\\t%s\\n' \"${cfg_addr:-}\"\n" +
    "  printf 'cfg_gateway\\t%s\\n' \"${cfg_gw:-}\"\n" +
    "  printf 'cfg_dns\\t%s\\n' \"${cfg_dns:-}\"\n" +
    "  printf 'route_metric\\t%s\\n' \"${route_metric:--1}\"\n" +
    "fi\n"

  function refresh() {
    if (statusProc.running) return
    statusProc.command = ["bash", "-c", statusScript, "ethernet-status", iface, root.opened ? "1" : "0"]
    statusProc.running = true
  }

  Process {
    id: statusProc
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root.info = Model.parseKeyValue(text) }
  }

  Timer {
    id: pollTimer
    interval: 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onIfaceChanged: { formMode = "auto"; refresh() }
  onOpenedChanged: {
    if (opened) {
      refresh()
    } else {
      statsGrid.reset()
      staticPanelOpen = false
      manualEntryOpen = false
    }
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(12)

    // ---------- Hero: icon · name + status · connect switch ----------
    Item {
      width: parent.width
      implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

      Text {
        id: heroIcon
        textFormat: Text.PlainText
        text: root.icon
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.display
        opacity: root.iconOpacity
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      RowLayout {
        id: heroActions
        spacing: Style.space(8)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        Button {
          text: root.isPrimary ? "Primary" : "Set primary"
          tooltipText: root.isPrimary ? "This is the preferred route for internet traffic" : "Prefer Ethernet for internet traffic over Wi-Fi"
          fontSize: Style.font.caption
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          active: root.isPrimary
          visible: root.isConnected
          enabled: !root.isPrimary
          Layout.alignment: Qt.AlignVCenter
          hasCursor: root.currentGroupId === "hero" && root.cursorItem === 0
          onClicked: root.setRouteMetric(Model.PRIMARY_METRIC)
        }

        ToggleSwitch {
          id: connectSwitch
          checked: root.isConnected
          busy: root.busy
          enabled: root.hasProfile && root.hasCable
          foreground: root.bar.foreground
          Layout.alignment: Qt.AlignVCenter
          hasCursor: root.currentGroupId === "hero" && root.cursorItem === (root.isConnected ? 1 : 0)
          onToggled: root.isConnected ? root.disconnectEthernet() : root.connectEthernet()

          PanelToolTip {
            visible: connectSwitch.containsMouse
            text: !root.hasProfile ? "No wired profile yet"
              : !root.hasCable ? "Plug in a cable first"
              : (root.isConnected ? "Disconnect" : "Connect")
            fontFamily: root.bar.fontFamily
          }
        }
      }

      Column {
        id: heroLabels
        anchors.left: heroIcon.right
        anchors.leftMargin: Style.space(14)
        anchors.right: heroActions.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: "Ethernet" + (root.speedLabel !== "" ? " (" + root.speedLabel + ")" : "")
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          textFormat: Text.PlainText
          text: (root.pendingAction !== "" ? "Working…" : root.statusLine).toUpperCase()
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }

    // ---------- Live stats ----------
    PanelSeparator {
      visible: root.isConnected
      foreground: root.bar.foreground
    }

    StatsGrid {
      id: statsGrid
      width: parent.width
      bar: root.bar
      info: root.info
      visibleGrid: root.isConnected
      onSustainedPacketLoss: root.recoverConnection()
    }

    // ---------- DHCP / Static IP ----------
    PanelSeparator {
      foreground: root.bar.foreground
    }

    Column {
      width: parent.width
      spacing: Style.space(10)

      PanelSectionHeader {
        text: "ETHERNET IPV4 CONFIGURATION"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }

      Text {
        textFormat: Text.PlainText
        visible: !root.hasProfile
        text: "Plug in a cable once so NetworkManager can create a wired profile."
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        width: parent.width
      }

      // Always visible, not tucked behind a disclosure -- clicking "Static"
      // is itself what opens the fields below; clicking it again (or
      // closing the whole panel) is what closes them back up.
      Row {
        visible: root.hasProfile
        width: parent.width
        spacing: Style.space(6)

        readonly property real cellWidth: (width - spacing) / 2

        Button {
          text: "DHCP"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          width: parent.cellWidth
          active: root.formMode === "auto"
          hasCursor: root.currentGroupId === "mode" && root.cursorItem === 0
          onClicked: root.selectMode("auto")
        }

        Button {
          text: "Static"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          width: parent.cellWidth
          active: root.formMode === "manual"
          hasCursor: root.currentGroupId === "mode" && root.cursorItem === 1
          onClicked: root.selectMode("manual")
        }
      }

      // The applied static profile's name, if any -- kept visible right
      // under the DHCP/Static row regardless of whether the fields below
      // are open, so it doesn't require reopening them just to check.
      Text {
        textFormat: Text.PlainText
        visible: root.currentProfileName !== ""
        text: root.currentProfileName
        color: Qt.darker(root.bar.foreground, 1.2)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
      }

      // Collapsing container, opened/closed only by the Static button (or
      // the panel closing) -- not by switching back to DHCP mid-edit.
      Item {
        id: staticFormClip
        width: parent.width
        clip: true
        visible: height > 0
        height: (root.hasProfile && root.staticPanelOpen) ? staticForm.implicitHeight : 0

        Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Column {
          id: staticForm
          width: parent.width
          spacing: Style.space(10)

          ProfileList {
            id: profileList
            width: parent.width
            bar: root.bar
            currentAddress: root.addressField
            currentGateway: root.gatewayField
            currentDns: root.dnsField
            onApplyRequested: function(profile) { root.applyProfileToForm(profile) }
            cursorRowIndex: root.currentGroupId.indexOf("profile-") === 0 ? parseInt(root.currentGroupId.substring(8), 10) : -1
            cursorRowItem: root.cursorItem
            addToggleHasCursor: root.currentGroupId === "add-profile"
          }

          Text {
            textFormat: Text.PlainText
            visible: root.lastError !== ""
            text: root.lastError
            color: root.bar.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }

          PanelSeparator {
            foreground: root.bar.foreground
          }

          // Raw address/gateway/DNS fields only matter for typing a
          // brand-new config or editing one -- applying a saved profile
          // (above) never needs them, so they stay hidden until asked for.
          Button {
            visible: !root.manualEntryOpen
            text: "Enter manually…"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            width: parent.width
            hasCursor: root.currentGroupId === "manual-toggle"
            onClicked: root.manualEntryOpen = true
          }

              Item {
                id: manualEntryClip
                width: parent.width
                clip: true
                visible: height > 0
                height: root.manualEntryOpen ? manualEntryForm.implicitHeight : 0

                Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                Column {
                  id: manualEntryForm
                  width: parent.width
                  spacing: Style.space(10)

                  TextField {
                    id: addressInput
                    width: parent.width
                    placeholderText: "IP Address / prefix (e.g. 192.168.1.50/24)"
                    font.pixelSize: Style.font.bodySmall
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlGap
                    verticalPadding: Style.spacing.controlPaddingY
                    onTextChanged: root.addressField = text
                    onAccepted: if (root.canApply) root.applyStatic()
                  }

                  TextField {
                    id: gatewayInput
                    width: parent.width
                    placeholderText: "Gateway (optional)"
                    font.pixelSize: Style.font.bodySmall
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlGap
                    verticalPadding: Style.spacing.controlPaddingY
                    onTextChanged: root.gatewayField = text
                    onAccepted: if (root.canApply) root.applyStatic()
                  }

                  TextField {
                    id: dnsInput
                    width: parent.width
                    placeholderText: "DNS servers (optional, space or comma separated)"
                    font.pixelSize: Style.font.bodySmall
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlGap
                    verticalPadding: Style.spacing.controlPaddingY
                    onTextChanged: root.dnsField = text
                    onAccepted: if (root.canApply) root.applyStatic()
                  }

                  Button {
                    text: root.pendingAction === "apply-static" ? "Applying…" : "Apply"
                    fontSize: Style.font.bodySmall
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                    bordered: true
                    width: parent.width
                    enabled: root.canApply && !root.busy
                    onClicked: root.applyStatic()
                  }
                }
              }
            }
          }
        }
      }

  // Static-IP text fields own their own keys while focused -- used by
  // Panel.qml's PanelKeyCatcher.blocked so h/j/k/l and space type normally.
  // Gated on manualEntryOpen, not just .activeFocus: a successful apply
  // collapses the fields asynchronously (see the "apply-static" Process
  // exit handler above) without anything explicitly blurring them first,
  // and Qt Quick doesn't clear activeFocus just because an item became
  // invisible -- without this gate, .activeFocus alone would stay stuck
  // true forever on a field nobody can even see anymore, and every future
  // keypress would silently type into it instead of navigating.
  readonly property bool anyFieldFocused: (root.manualEntryOpen && (addressInput.activeFocus || gatewayInput.activeFocus || dnsInput.activeFocus)) || profileList.anyFieldFocused
}
