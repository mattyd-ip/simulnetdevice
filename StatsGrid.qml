import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Ping / packet loss / throughput / IP / gateway grid for one interface.
// Each instance owns its own throughput+ping sample history, so two of
// these (one per interface) track independently rather than sharing one
// default-route sample the way the built-in omarchy.network widget does.
Item {
  id: root

  required property QtObject bar
  // Parsed key/value status for this interface: iface, ip, prefix, gateway,
  // rx_bytes, tx_bytes, router_ping_ms, internet_ping_ms -- same shape the
  // owning section's status script already produces.
  property var info: ({})
  property bool visibleGrid: true

  property real prevRxBytes: 0
  property real prevTxBytes: 0
  property real prevSampleTime: 0
  property string prevIface: ""
  property real downloadRate: 0
  property real uploadRate: 0
  property var internetPingSamples: []
  property real internetPingLatency: -1
  property int internetPingPacketLoss: 0
  readonly property int pingHistoryWindow: 24
  readonly property int pingAverageWindow: 5
  readonly property bool hasInternetPing: internetPingSamples.length > 0
  readonly property bool hasTransferStats: info.rx_bytes !== undefined

  implicitHeight: visibleGrid ? grid.implicitHeight : 0
  visible: visibleGrid

  onInfoChanged: {
    var t = Model.throughputState({
      prevIface: prevIface, prevRxBytes: prevRxBytes, prevTxBytes: prevTxBytes,
      prevSampleTime: prevSampleTime, downloadRate: downloadRate, uploadRate: uploadRate
    }, info, Date.now() / 1000)
    prevIface = t.prevIface
    prevRxBytes = t.prevRxBytes
    prevTxBytes = t.prevTxBytes
    prevSampleTime = t.prevSampleTime
    downloadRate = t.downloadRate
    uploadRate = t.uploadRate

    var p = Model.pingLatencyState({ internetPingSamples: internetPingSamples }, info, pingHistoryWindow, pingAverageWindow)
    internetPingSamples = p.internetPingSamples
    internetPingLatency = p.internetPingLatency
    internetPingPacketLoss = p.internetPingPacketLoss
  }

  // Reset so reopening the panel (or the interface dropping out) doesn't
  // carry over a rate computed from a sample taken minutes ago.
  function reset() {
    prevIface = ""
    prevRxBytes = 0
    prevTxBytes = 0
    prevSampleTime = 0
    downloadRate = 0
    uploadRate = 0
    internetPingSamples = []
    internetPingLatency = -1
    internetPingPacketLoss = 0
  }

  function copyToClipboard(value) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
  }

  GridLayout {
    id: grid
    width: parent.width
    columns: 4
    columnSpacing: Style.space(20)
    rowSpacing: Style.spacing.labelGap

    InfoLabel { text: "Ping" }
    DetailValue {
      text: Model.formatPingLatency(root.internetPingLatency, root.hasInternetPing)
      color: root.internetPingPacketLoss > 0 ? root.bar.urgent : root.bar.foreground
    }
    InfoLabel { text: "Packet Loss" }
    DetailValue {
      text: Model.formatPacketLoss(root.internetPingPacketLoss, root.hasInternetPing)
      color: root.internetPingPacketLoss > 0 ? root.bar.urgent : root.bar.foreground
    }

    InfoLabel { text: "Receiving" }
    DetailValue { text: root.hasTransferStats ? Model.formatRate(root.downloadRate) : "--" }
    InfoLabel { text: "Sending" }
    DetailValue { text: root.hasTransferStats ? Model.formatRate(root.uploadRate) : "--" }

    InfoLabel { text: "Downloaded" }
    DetailValue { text: root.hasTransferStats ? Model.formatBytes(parseFloat(root.info.rx_bytes || "0")) : "--" }
    InfoLabel { text: "Uploaded" }
    DetailValue { text: root.hasTransferStats ? Model.formatBytes(parseFloat(root.info.tx_bytes || "0")) : "--" }

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
}
