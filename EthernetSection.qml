import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import Quickshell.Networking
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Ethernet status, connect/disconnect, and DHCP/static IPv4, scoped
// directly to the wired interface (`ip`/`nmcli ... dev $iface`) rather
// than the default route. Embedded as content inside Panel.qml's popup.
Item {
  id: root

  required property QtObject bar
  // Ping sampling only runs while true; carrier/IP/route polling keeps
  // running regardless.
  property bool opened: false

  // ---------- Keyboard cursor ----------
  // Driven from Panel.qml. cursorGroup is -1 when the cursor belongs to
  // WifiSection.
  property bool cursorActive: false
  property int cursorGroup: -1
  property int cursorItem: -1

  // Groups, top to bottom: "hero", "mode" (when a profile exists), then --
  // only while staticPanelOpen -- one "profile-N" group per saved profile,
  // "add-profile", and "manual-toggle" (when manualEntryOpen is false).
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

  // The saved profile (if any) matching the currently-applied static config.
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
  // Set by Panel.qml to the sibling section's current metric.
  property var primaryCompareMetric: undefined
  // A metric change requires `connection up` to take effect.
  readonly property string setMetricScript:
    "conn=$1; metric=$2\n" +
    "nmcli connection modify \"$conn\" ipv4.route-metric \"$metric\" || exit 1\n" +
    "nmcli connection up \"$conn\" >/dev/null 2>&1 || true\n"

  function setRouteMetric(metric) {
    if (!hasProfile) return
    if (!isConnected) return
    var promoting = metric === Model.PRIMARY_METRIC
    // If the metric already matches, skip the round-trip; still emit
    // routeMetricApplied when promoting.
    if (parseInt(metric, 10) === routeMetric) {
      if (promoting) root.routeMetricApplied()
      return
    }
    metricProc.command = ["bash", "-c", setMetricScript, "ethernet-metric", info.connection, String(metric)]
    // routeMetricApplied fires only on promotion, not demotion.
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

  // Local form state for the DHCP/Static choice, separate from the
  // profile's real `ipv4.method`; nothing is written until Apply.
  property string formMode: "auto"  // "auto" | "manual"
  property string addressField: ""
  property string gatewayField: ""
  property string dnsField: ""
  property string pendingAction: ""  // "connect" | "disconnect" | "apply-dhcp" | "apply-static"
  readonly property bool busy: pendingAction !== ""
  property string lastError: ""
  // Set when an apply fails because there's no carrier; retried by
  // onHasCableChanged once the cable is plugged in.
  property string retryActionOnCarrier: ""  // "" | "apply-dhcp" | "apply-static"

  readonly property bool canApply: Model.canApplyStatic({ address: addressField, gateway: gatewayField })

  // Fields are set imperatively, not via a `text: root.addressField` binding.
  function seedStaticFields() {
    var seed = Model.staticFormDefaults(info)
    addressField = seed.address
    gatewayField = seed.gateway
    dnsField = seed.dns
    addressInput.text = seed.address
    gatewayInput.text = seed.gateway
    dnsInput.text = seed.dns
  }

  // Called from ProfileList: fills the form from a saved profile and
  // applies it immediately.
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

  property bool staticPanelOpen: false
  property bool manualEntryOpen: false
  onManualEntryOpenChanged: if (manualEntryOpen) Qt.callLater(function() { addressInput.forceActiveFocus() })

  function selectMode(mode) {
    if (busy) cancelInFlightApply()
    if (mode === "auto") {
      formMode = "auto"
      manualEntryOpen = false
      staticPanelOpen = false
      applyDhcp()
      return
    }
    // A second click on "Static" while open closes it; formMode only
    // reverts to "auto" if no static profile is applied.
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

  // Stops any in-flight actionProc/retry/recovery cycle.
  function cancelInFlightApply() {
    applyRetryTimer.stop()
    retryActionOnCarrier = ""
    applyRetriesLeft = 0
    recoveryPhase = ""
    recovering = false
    actionGeneration += 1
    if (actionProc.running) actionProc.running = false
    pendingAction = ""
    lastError = ""
  }

  // Syncs formMode from the live profile's method into "manual"; never
  // forces "manual" back to "auto" on its own.
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

  // Bumped by cancelInFlightApply() and every dispatch below.
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

  // Recovers from sustained ping loss with a disconnect followed by a
  // reconnect. recoveryPhase tracks which half is in flight.
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

  // IPv4 only. addr/gw/dns are passed positionally, not interpolated into
  // the script string. Cycles the connection down before bringing it up.
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

  // Redoes the pending apply once the cable goes live.
  onHasCableChanged: {
    if (!hasCable || retryActionOnCarrier === "") return
    var action = retryActionOnCarrier
    retryActionOnCarrier = ""
    if (action === "apply-static") applyStatic()
    else if (action === "apply-dhcp") applyDhcp()
  }

  // Retries a failed apply-dhcp/apply-static up to maxApplyRetries times,
  // 2s apart, re-firing the same actionProc.command.
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
      // Ignores a stale exit from a process cancelInFlightApply() killed.
      if (dispatchGeneration !== root.actionGeneration) return
      var isApplyAction = root.pendingAction === "apply-dhcp" || root.pendingAction === "apply-static"
      if (exitCode !== 0 && isApplyAction && !root.hasCable) {
        // No cable: wait for onHasCableChanged instead of retrying now.
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
        // The disconnect half failed; clear recovery state here too.
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
        // Collapses the manual-entry fields on a successful apply; left
        // open on failure.
        root.manualEntryOpen = false
      }
      root.pendingAction = ""
      root.refresh()
    }
  }

  // The ping to 1.1.1.1 (1s timeout) only runs while do_ping is 1 (the
  // popup is open); carrier/ip/route/nmcli reads always run.
  readonly property string statusScript:
    "iface=$1; do_ping=$2\n" +
    "if [[ -z $iface || ! -e /sys/class/net/$iface ]]; then printf 'state\\tno-device\\n'; exit 0; fi\n" +
    "carrier=$(cat \"/sys/class/net/$iface/carrier\" 2>/dev/null)\n" +
    "speed=$(cat \"/sys/class/net/$iface/speed\" 2>/dev/null)\n" +
    "addr_json=$(ip -4 -j addr show dev \"$iface\" 2>/dev/null)\n" +
    // Prefers the address `ip` flags `dynamic` over the first-listed one.
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
    // -I $iface scopes the ping to this interface.
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

      // Header + DHCP/Static row, spaced to match WifiSection's band-selector
      // block (see bandSection).
      Column {
        width: parent.width
        spacing: Style.space(6)

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

        // DHCP/Static buttons; always visible.
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
      }

      // The applied static profile's name, if any.
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

          // Reveals the raw address/gateway/DNS fields.
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

  // True while a static-IP field is focused; used by Panel.qml's
  // PanelKeyCatcher.blocked. Gated on manualEntryOpen, not just .activeFocus.
  readonly property bool anyFieldFocused: (root.manualEntryOpen && (addressInput.activeFocus || gatewayInput.activeFocus || dnsInput.activeFocus)) || profileList.anyFieldFocused
}
