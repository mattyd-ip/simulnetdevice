import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Ping / packet loss / throughput / IP / gateway grid for one interface.
// Each instance owns its own throughput+ping sample history.
Item {
  id: root

  required property QtObject bar
  // Parsed key/value status for this interface: iface, ip, prefix, gateway,
  // rx_bytes, tx_bytes, internet_ping_ms.
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

  // Fired when the most recent sustainedLossThreshold samples are all lost.
  readonly property int sustainedLossThreshold: 5  // ~15s at the 3s poll interval
  signal sustainedPacketLoss()

  // ---------- Ping target ----------
  property string pingTarget: Model.DEFAULT_PING_TARGET
  property bool linkPingTargets: true
  property bool editingPingTarget: false
  property string pingTargetDraft: ""
  readonly property bool pingTargetValid: Model.isValidIpv4(pingTargetDraft)
  // Used by the owning section's anyFieldFocused, same convention as
  // ProfileList.qml/WifiScanList.qml's own anyFieldFocused.
  readonly property bool anyFieldFocused: editingPingTarget && pingTargetInput.activeFocus
  signal pingTargetSaveRequested(string value)
  signal linkPingTargetsToggled(bool linked)

  function openPingTargetEditor() {
    pingTargetDraft = pingTarget
    editingPingTarget = true
  }
  function cancelPingTargetEdit() {
    editingPingTarget = false
  }
  function savePingTarget() {
    if (!pingTargetValid) return
    pingTargetSaveRequested(pingTargetDraft)
    editingPingTarget = false
  }

  // Keeps an already-open editor in sync with a linked edit made from the
  // sibling section, and drops ping history so the rolling average doesn't
  // blend samples from the old target with the new one.
  onPingTargetChanged: {
    pingTargetDraft = pingTarget
    resetPingHistory()
  }

  implicitHeight: visibleGrid ? contentColumn.implicitHeight : 0
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

    if (Model.isSustainedPingLoss(internetPingSamples, sustainedLossThreshold)) sustainedPacketLoss()
  }

  function resetPingHistory() {
    internetPingSamples = []
    internetPingLatency = -1
    internetPingPacketLoss = 0
  }

  // Clears throughput and ping history.
  function reset() {
    prevIface = ""
    prevRxBytes = 0
    prevTxBytes = 0
    prevSampleTime = 0
    downloadRate = 0
    uploadRate = 0
    resetPingHistory()
  }

  function copyToClipboard(value) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
  }

  Column {
    id: contentColumn
    width: parent.width
    spacing: Style.space(8)

    GridLayout {
      id: grid
      width: parent.width
      columns: 4
      columnSpacing: Style.space(20)
      rowSpacing: Style.spacing.labelGap

      RowLayout {
        spacing: Style.space(2)

        InfoLabel { text: "Ping" }
        PanelActionButton {
          iconText: "󰒓"
          tooltipText: "Ping target"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onClicked: root.editingPingTarget ? root.cancelPingTargetEdit() : root.openPingTargetEditor()
        }
      }
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

    // Ping-target editor: collapsed unless the gear next to "Ping" is toggled.
    Item {
      id: pingTargetEditorClip
      width: parent.width
      clip: true
      visible: height > 0
      height: root.editingPingTarget ? pingTargetEditor.implicitHeight : 0

      Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

      Column {
        id: pingTargetEditor
        width: parent.width
        spacing: Style.space(8)

        Row {
          spacing: Style.space(6)

          ToggleSwitch {
            checked: root.linkPingTargets
            foreground: root.bar.foreground
            onToggled: root.linkPingTargetsToggled(!root.linkPingTargets)
          }
          // The shared ToggleSwitch's on/off track shading is theme-derived
          // and can read as low-contrast; this badge makes the state
          // unambiguous regardless of theme.
          Text {
            textFormat: Text.PlainText
            text: root.linkPingTargets ? "On" : "Off"
            anchors.verticalCenter: parent.verticalCenter
            color: root.linkPingTargets ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            text: "Shared Ping-target"
            anchors.verticalCenter: parent.verticalCenter
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: pingTargetInput
            Layout.fillWidth: true
            text: root.pingTargetDraft
            placeholderText: Model.DEFAULT_PING_TARGET
            font.pixelSize: Style.font.bodySmall
            foreground: root.bar.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onTextChanged: root.pingTargetDraft = text
            onAccepted: root.savePingTarget()
          }
          PanelActionButton {
            iconText: "󰄬"
            tooltipText: "Save"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            enabled: root.pingTargetValid
            onClicked: root.savePingTarget()
          }
          PanelActionButton {
            iconText: "󰅙"
            tooltipText: "Cancel"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.cancelPingTargetEdit()
          }
        }
      }
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
