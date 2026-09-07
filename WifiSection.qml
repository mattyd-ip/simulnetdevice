import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import Quickshell.Networking
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Wi-Fi status + radio on/off + primary-route selection + nearby-network
// scanning/joining/forgetting, scoped directly to the Wi-Fi interface rather
// than the default route -- same reasoning as EthernetSection.qml. Band
// selection and WPA-Enterprise (802.1x) networks stay the built-in
// omarchy.network widget's job for now (see docs/plans -- Non-goals).
Item {
  id: root

  required property QtObject bar
  property bool opened: false

  readonly property var networkDevices: Networking.devices ? Networking.devices.values : []
  readonly property var wifiDevice: findDevice(DeviceType.Wifi)
  readonly property string iface: wifiDevice ? wifiDevice.name : ""

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
  readonly property string linkState: Model.wifiLinkState(info, Networking.wifiEnabled)
  readonly property bool hasAdapter: linkState !== "no-device"
  readonly property bool isConnected: linkState === "connected"
  readonly property bool hasProfile: !!info.connection
  readonly property string statusLine: Model.wifiStatusText(linkState)
  readonly property string ssid: isConnected ? (info.ssid || "Wi-Fi") : "Wi-Fi"
  readonly property int signal: parseInt(info.signal, 10) || 0

  readonly property string icon: isConnected ? Model.wifiIconFor(signal) : "󰤮"
  readonly property real iconOpacity: linkState === "disabled" ? 0.4 : (isConnected ? 1.0 : 0.6)

  // Public interface for Panel.qml's primary-route coordination -- same
  // shape as EthernetSection's.
  function connectionName() { return info.connection || "" }
  readonly property int routeMetric: parseInt(info.route_metric, 10)
  readonly property bool isPrimary: Model.isPrimary(info.route_metric, primaryCompareMetric)
  property var primaryCompareMetric: undefined
  // See EthernetSection's identical comment: a metric change needs a
  // `connection up` to actually move into the live routing table.
  readonly property string setMetricScript:
    "conn=$1; metric=$2\n" +
    "nmcli connection modify \"$conn\" ipv4.route-metric \"$metric\" || exit 1\n" +
    "nmcli connection up \"$conn\" >/dev/null 2>&1 || true\n"

  function setRouteMetric(metric) {
    if (!hasProfile) return
    // See EthernetSection's identical comment: hasProfile stays true even
    // while disconnected (fallback profile-name lookup), so without this
    // guard the sibling's demote-to-secondary cross-wire would force
    // `connection up` here and silently re-enable an interface the user
    // just explicitly disabled.
    if (!isConnected) return
    var promoting = metric === Model.PRIMARY_METRIC
    // Skip the actual round-trip when nothing would actually change --
    // `connection up` forces a real Wi-Fi disconnect/reconnect (confirmed
    // live), which every unrelated "Set primary" click on Ethernet would
    // otherwise trigger here for no reason. But a genuine "make me primary"
    // click still has to tell the sibling to demote even when *my* metric
    // already happens to be right -- see EthernetSection's identical
    // comment (two connections tied at the same metric could otherwise
    // never be untied).
    if (parseInt(metric, 10) === routeMetric) {
      if (promoting) root.routeMetricApplied()
      return
    }
    metricProc.command = ["bash", "-c", setMetricScript, "wifi-metric", info.connection, String(metric)]
    // Only a genuine promotion to primary should tell the sibling to
    // demote itself -- if the demotion call below also emitted this, the
    // sibling's own demote-in-response would bounce right back and demote
    // us too, forever, both settling on SECONDARY_METRIC no matter which
    // side was actually clicked (confirmed live: both connections' saved
    // profiles converge on 600).
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

  // The one toggle here is the radio itself (Networking.wifiEnabled), not a
  // per-profile connect/disconnect like Ethernet's: there's no scan/join UI
  // in this plugin to pick *which* network to bring up, and NetworkManager's
  // own autoconnect already handles reconnecting to a known SSID once the
  // radio is back on -- same behavior the built-in widget's power switch
  // relies on.
  function toggleRadio() {
    Networking.wifiEnabled = !Networking.wifiEnabled
    Qt.callLater(function() { root.refresh() })
  }

  // Confirmed live: a real network-side condition (not something this
  // plugin's own ping check imagines) can leave Wi-Fi passing ARP but
  // dropping everything else indefinitely -- it does NOT clear on its own
  // no matter how long you wait, only a genuine radio off/on (a real
  // 802.11 disassociate + reassociate, same as the manual "Turn Wi-Fi off"
  // toggle) restores it. `recovering` both drives the button text and,
  // more importantly, blocks re-triggering every single poll while still
  // stuck -- and `recoveryCooldownTimer` blocks re-triggering right after
  // a recovery attempt too, so a case this doesn't actually fix can't turn
  // into a radio flapping on and off every ~15s forever.
  property bool recovering: false
  property bool recoveryOnCooldown: false
  function recoverConnection() {
    if (recovering || recoveryOnCooldown || !isConnected) return
    recovering = true
    Networking.wifiEnabled = false
    recoveryToggleTimer.start()
  }

  Timer {
    id: recoveryToggleTimer
    interval: 1500
    repeat: false
    onTriggered: {
      Networking.wifiEnabled = true
      root.recovering = false
      root.recoveryOnCooldown = true
      recoveryCooldownTimer.start()
      Qt.callLater(function() { root.refresh() })
    }
  }

  Timer {
    id: recoveryCooldownTimer
    interval: 30000
    repeat: false
    onTriggered: root.recoveryOnCooldown = false
  }

  readonly property string statusScript:
    "iface=$1; do_ping=$2\n" +
    "if [[ -z $iface ]]; then printf 'state\\tno-device\\n'; exit 0; fi\n" +
    "nmstate=$(nmcli -t -f GENERAL.STATE dev show \"$iface\" 2>/dev/null | cut -d: -f2-)\n" +
    "conn=$(nmcli -t -f GENERAL.CONNECTION dev show \"$iface\" 2>/dev/null | cut -d: -f2-)\n" +
    "signal=$(nmcli -t -f IN-USE,SIGNAL dev wifi list ifname \"$iface\" --rescan no 2>/dev/null | awk -F: '$1==\"*\"{print $2; exit}')\n" +
    "addr_json=$(ip -4 -j addr show dev \"$iface\" 2>/dev/null)\n" +
    "read -r ip prefix <<<\"$(printf '%s' \"$addr_json\" | jq -r '\n" +
    "  .[0].addr_info as $a\n" +
    "  | ([$a[] | select(.family==\"inet\" and (.dynamic // false))] + [$a[] | select(.family==\"inet\")])\n" +
    "  | .[0]\n" +
    "  | if . then \"\\(.local) \\(.prefixlen)\" else \"\" end\n" +
    "' 2>/dev/null)\"\n" +
    "gateway=$(ip -4 route show dev \"$iface\" 2>/dev/null | awk '/^default/ { print $3; exit }')\n" +
    "if [[ -z $conn || $conn == '--' ]]; then\n" +
    "  conn=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2 == \"802-11-wireless\" { print $1; exit }')\n" +
    "fi\n" +
    "printf 'iface\\t%s\\n' \"$iface\"\n" +
    "printf 'nmstate\\t%s\\n' \"${nmstate:-}\"\n" +
    "printf 'ssid\\t%s\\n' \"${conn:-}\"\n" +
    "printf 'signal\\t%s\\n' \"${signal:-}\"\n" +
    "printf 'ip\\t%s\\n' \"${ip:-}\"\n" +
    "printf 'prefix\\t%s\\n' \"${prefix:-}\"\n" +
    "printf 'gateway\\t%s\\n' \"${gateway:-}\"\n" +
    "if [[ -r /sys/class/net/$iface/statistics/rx_bytes ]]; then printf 'rx_bytes\\t%s\\n' \"$(cat /sys/class/net/$iface/statistics/rx_bytes)\"; fi\n" +
    "if [[ -r /sys/class/net/$iface/statistics/tx_bytes ]]; then printf 'tx_bytes\\t%s\\n' \"$(cat /sys/class/net/$iface/statistics/tx_bytes)\"; fi\n" +
    "if [[ $do_ping == 1 ]]; then\n" +
    // See EthernetSection's identical comment: -I $iface keeps this row's
    // reading scoped to this interface, not whichever one owns the default
    // route right now.
    "  ms=$(LC_ALL=C ping -n -c1 -W1 -I \"$iface\" 1.1.1.1 2>/dev/null | awk -F'time[=<]' '/time[=<]/ { split($2, p, \" \"); print p[1]; exit }')\n" +
    "  printf 'internet_ping_ms\\t%s\\n' \"${ms:-}\"\n" +
    "fi\n" +
    "if [[ -n $conn ]]; then\n" +
    "  method=$(nmcli -g ipv4.method connection show \"$conn\" 2>/dev/null)\n" +
    "  route_metric=$(nmcli -g ipv4.route-metric connection show \"$conn\" 2>/dev/null)\n" +
    "  printf 'connection\\t%s\\n' \"$conn\"\n" +
    "  printf 'method\\t%s\\n' \"${method:-auto}\"\n" +
    "  printf 'route_metric\\t%s\\n' \"${route_metric:--1}\"\n" +
    "fi\n"

  function refresh() {
    if (statusProc.running) return
    statusProc.command = ["bash", "-c", statusScript, "wifi-status", iface, root.opened ? "1" : "0"]
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

  onIfaceChanged: refresh()
  onOpenedChanged: {
    if (opened) refresh()
    else statsGrid.reset()
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(12)

    // ---------- Hero: icon · name + status · primary/power ----------
    Item {
      id: heroItem
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
          tooltipText: root.isPrimary ? "This is the preferred route for internet traffic" : "Prefer Wi-Fi for internet traffic over Ethernet"
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
          onClicked: root.setRouteMetric(Model.PRIMARY_METRIC)
        }

        ToggleSwitch {
          id: radioSwitch
          checked: Networking.wifiEnabled
          foreground: root.bar.foreground
          Layout.alignment: Qt.AlignVCenter
          onToggled: root.toggleRadio()

          PanelToolTip {
            visible: radioSwitch.containsMouse
            text: Networking.wifiEnabled ? "Turn Wi-Fi off" : "Turn Wi-Fi on"
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
          text: root.ssid
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          textFormat: Text.PlainText
          text: root.statusLine.toUpperCase()
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
      id: statsSeparator
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

    // ---------- Nearby networks ----------
    PanelSeparator {
      id: networksSeparator
      foreground: root.bar.foreground
    }

    WifiScanList {
      id: scanList
      width: parent.width
      bar: root.bar
      device: root.wifiDevice
      // Radio off means a scan can never complete -- gating on wifiEnabled
      // too keeps the scanner from spinning forever with nothing to show
      // for it (and matches the "only run while actually useful" cost
      // tradeoff already described below).
      active: root.opened && Networking.wifiEnabled
      extraHeight: root.extraForList
    }
  }

  // Set externally (by Panel.qml, in two-column mode) to the Ethernet
  // column's height, so the nearby-networks list can grow downward to
  // match instead of leaving blank space beside a taller Ethernet side.
  property real stretchTargetHeight: 0

  // Everything except the (possibly stretched) network list, computed
  // independently of scanList's actual rendered height -- reading
  // column.implicitHeight here instead would create a binding loop, since
  // that already includes whatever height extraForList gives the list.
  readonly property real naturalHeight:
    heroItem.implicitHeight + column.spacing
    + (root.isConnected ? statsSeparator.implicitHeight + column.spacing : 0)
    + (root.isConnected ? statsGrid.implicitHeight + column.spacing : 0)
    + networksSeparator.implicitHeight + column.spacing
    + scanList.unstretchedImplicitHeight

  readonly property real extraForList: Math.max(0, stretchTargetHeight - naturalHeight)

  // Exposed so Panel.qml's PanelKeyCatcher can block h/j/k/l-as-navigation
  // while a network's password field is focused.
  readonly property bool anyFieldFocused: scanList.anyFieldFocused
}
