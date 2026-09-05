import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Ethernet status + DHCP/static IP configuration. Lives alongside the
// built-in omarchy.network widget rather than inside it: that widget only
// ever reports on the interface currently holding the default route (see
// its Panel.qml `kind` property and omarchy-network-status), so a wired
// connection sitting quietly next to an active Wi-Fi link is invisible in
// it. Every query here is scoped directly to the wired interface (`ip ...
// dev $iface`, `nmcli dev show $iface`) so it stays accurate regardless of
// which device owns the default route.
Panel {
  id: root
  moduleName: "netctl"
  ipcTarget: "netctl"
  manageIpc: false

  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 3)), 10)
    if (!isFinite(n) || n < 1) n = 3
    return n
  }

  readonly property var networkDevices: Networking.devices ? Networking.devices.values : []
  readonly property var wiredDevice: findDevice(DeviceType.Wired)
  readonly property string iface: wiredDevice ? wiredDevice.name : ""

  // Prefer a connected wired device: a box can expose more than one wired
  // NIC (onboard + dock, say), and the first-enumerated one may be idle.
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

  readonly property string icon: "󰈀"
  readonly property real iconOpacity: {
    if (linkState === "connected") return 1.0
    if (linkState === "connecting") return 0.75
    return 0.4
  }

  visible: hasAdapter
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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

  readonly property bool canApply: Model.canApplyStatic({ address: addressField, gateway: gatewayField })

  // Fields are set imperatively (not via a `text: root.addressField`
  // binding) because typing in a TextField severs a declarative binding on
  // that property for good -- these fields persist for the panel's whole
  // lifetime (unlike, say, the wifi passphrase prompt, whose row is
  // recreated on every scan), so a broken binding would silently stop
  // reseeding after the user's first keystroke.
  function seedStaticFields() {
    var seed = Model.staticFormDefaults(info)
    addressField = seed.address
    gatewayField = seed.gateway
    dnsField = seed.dns
    addressInput.text = seed.address
    gatewayInput.text = seed.gateway
    dnsInput.text = seed.dns
  }

  function selectMode(mode) {
    if (busy) return
    if (mode === "auto") {
      formMode = "auto"
      applyDhcp()
      return
    }
    if (formMode !== "manual") seedStaticFields()
    formMode = "manual"
  }

  function syncFormMode() {
    if (busy) return
    var manual = Model.isManualMethod(info.method)
    if (manual && formMode !== "manual") seedStaticFields()
    formMode = manual ? "manual" : "auto"
  }

  onInfoChanged: syncFormMode()

  function connectEthernet() {
    if (busy || !hasProfile) return
    pendingAction = "connect"
    lastError = ""
    actionProc.command = ["nmcli", "connection", "up", info.connection]
    actionProc.running = true
  }

  function disconnectEthernet() {
    if (busy || !iface) return
    pendingAction = "disconnect"
    lastError = ""
    actionProc.command = ["nmcli", "device", "disconnect", iface]
    actionProc.running = true
  }

  // IPv4 only, and args are passed positionally rather than interpolated
  // into the script string -- user-typed IP/gateway/DNS values never touch
  // shell parsing.
  readonly property string applyIpv4Script:
    "mode=$1; conn=$2; addr=$3; gw=$4; dns=$5\n" +
    "if [[ -z $conn ]]; then echo 'No connection profile' >&2; exit 1; fi\n" +
    "if [[ $mode == static ]]; then\n" +
    "  nmcli connection modify \"$conn\" ipv4.method manual ipv4.addresses \"$addr\" ipv4.gateway \"$gw\" ipv4.dns \"$dns\" ipv4.ignore-auto-dns yes || exit 1\n" +
    "else\n" +
    "  nmcli connection modify \"$conn\" ipv4.method auto ipv4.addresses '' ipv4.gateway '' ipv4.dns '' ipv4.ignore-auto-dns no || exit 1\n" +
    "fi\n" +
    "nmcli connection up \"$conn\" >/dev/null 2>&1 || true\n"

  function applyDhcp() {
    if (busy || !hasProfile) return
    pendingAction = "apply-dhcp"
    lastError = ""
    actionProc.command = ["bash", "-c", applyIpv4Script, "ethernet-ipv4", "dhcp", info.connection, "", "", ""]
    actionProc.running = true
  }

  function applyStatic() {
    if (busy || !hasProfile || !canApply) return
    pendingAction = "apply-static"
    lastError = ""
    var dns = Model.normalizeDns(dnsField)
    actionProc.command = ["bash", "-c", applyIpv4Script, "ethernet-ipv4", "static", info.connection, addressField, gatewayField, dns]
    actionProc.running = true
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = String(actionStderr.text || actionStdout.text || "Command failed").trim()
      }
      root.pendingAction = ""
      root.refresh()
    }
  }

  readonly property string statusScript:
    "iface=$1\n" +
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
    "if [[ -n $conn ]]; then\n" +
    "  printf 'connection\\t%s\\n' \"$conn\"\n" +
    "  method=$(nmcli -g ipv4.method connection show \"$conn\" 2>/dev/null)\n" +
    "  cfg_addr=$(nmcli -g ipv4.addresses connection show \"$conn\" 2>/dev/null)\n" +
    "  cfg_gw=$(nmcli -g ipv4.gateway connection show \"$conn\" 2>/dev/null)\n" +
    "  cfg_dns=$(nmcli -g ipv4.dns connection show \"$conn\" 2>/dev/null)\n" +
    "  printf 'method\\t%s\\n' \"${method:-auto}\"\n" +
    "  printf 'cfg_address\\t%s\\n' \"${cfg_addr:-}\"\n" +
    "  printf 'cfg_gateway\\t%s\\n' \"${cfg_gw:-}\"\n" +
    "  printf 'cfg_dns\\t%s\\n' \"${cfg_dns:-}\"\n" +
    "fi\n"

  function refresh() {
    if (statusProc.running) return
    statusProc.command = ["bash", "-c", statusScript, "ethernet-status", iface]
    statusProc.running = true
  }

  Process {
    id: statusProc
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root.info = Model.parseKeyValue(text) }
  }

  Timer {
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onIfaceChanged: refresh()

  onOpenedChanged: if (opened) refresh()

  function copyToClipboard(value) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
  }

  IpcHandler {
    target: "netctl"
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Static-IP text fields own their own keys while focused -- h/j/k/l
      // and space are ordinary characters there.
      blocked: addressInput.activeFocus || gatewayInput.activeFocus || dnsInput.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero: icon · name + status · connect switch ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, connectSwitch.implicitHeight)

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

          ToggleSwitch {
            id: connectSwitch
            checked: root.isConnected
            busy: root.busy
            enabled: root.hasProfile && root.hasCable
            foreground: root.bar.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.isConnected ? root.disconnectEthernet() : root.connectEthernet()

            PanelToolTip {
              visible: connectSwitch.containsMouse
              text: !root.hasProfile ? "No wired profile yet"
                : !root.hasCable ? "Plug in a cable first"
                : (root.isConnected ? "Disconnect" : "Connect")
              fontFamily: root.bar.fontFamily
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: connectSwitch.left
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

        // ---------- Live IP details ----------
        PanelSeparator {
          visible: root.isConnected
          foreground: root.bar.foreground
        }

        GridLayout {
          visible: root.isConnected
          width: parent.width
          columns: 2
          columnSpacing: Style.space(20)
          rowSpacing: Style.spacing.labelGap

          InfoLabel { text: "IP Address" }
          DetailValue {
            text: root.info.ip && root.info.prefix ? root.info.ip + "/" + root.info.prefix : "--"
            copyable: !!root.info.ip
            tooltipText: "Copy IP"
          }
          InfoLabel { text: "Gateway" }
          DetailValue {
            text: root.info.gateway || "--"
            copyable: !!root.info.gateway
            tooltipText: "Copy gateway"
          }
        }

        // ---------- DHCP / Static IP ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "IPV4 CONFIGURATION"
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
              onClicked: root.selectMode("manual")
            }
          }

          // Collapsing container so switching back to DHCP slides the form
          // away instead of snapping.
          Item {
            id: staticFormClip
            width: parent.width
            clip: true
            visible: height > 0
            height: (root.hasProfile && root.formMode === "manual") ? staticForm.implicitHeight : 0

            Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

            Column {
              id: staticForm
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: addressInput
                width: parent.width
                placeholderText: "IP Address / prefix (e.g. 192.168.1.50/24)"
                font.pixelSize: Style.font.bodySmall
                foreground: root.bar.foreground
                horizontalPadding: Style.spacing.controlGap
                verticalPadding: Style.spacing.controlPaddingY
                onTextChanged: root.addressField = text
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

  component DetailValue: InfoValue {
    property bool copyable: false
    property string tooltipText: "Copy to clipboard"

    Layout.fillWidth: true
    horizontalAlignment: Text.AlignRight

    MouseArea {
      id: valueMouse
      anchors.fill: parent
      enabled: copyable && parent.text !== ""
      hoverEnabled: enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.copyToClipboard(parent.text)
    }

    PanelToolTip {
      visible: valueMouse.enabled && valueMouse.containsMouse
      text: tooltipText
      fontFamily: root.bar.fontFamily
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
