import QtQuick
import QtQuick.Controls
import Quickshell.Networking
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Nearby-network scanning, joining, and forgetting. Uses Quickshell's
// reactive WifiDevice/WifiNetwork objects (network.connect(),
// network.connectWithPsk(), network.forget()) rather than shelling out to
// nmcli.
Item {
  id: root

  required property QtObject bar
  // The WifiDevice found by the owning WifiSection, or null when there's no
  // Wi-Fi adapter.
  property var device: null
  property bool active: false
  // Index of the row under the keyboard cursor, or -1 when the cursor
  // belongs to some other group (set by WifiSection from Panel.qml's
  // central cursor controller).
  property int cursorIndex: -1
  onCursorIndexChanged: if (cursorIndex >= 0) Qt.callLater(function() {
    networkListView.positionViewAtIndex(cursorIndex, ListView.Contain)
  })

  // Keyboard-cursor entry points, mirroring activateRow/forgetRow by index.
  function activateByIndex(i) {
    var net = wifiNetworks[i]
    if (net) activateRow(net)
  }
  function forgetByIndex(i) {
    var net = wifiNetworks[i]
    if (net && canForgetNetwork(net)) forgetRow(net.ssid)
  }

  readonly property var networkObjects: device && device.networks ? device.networks.values : []
  property var wifiNetworks: []
  // Networks sorted connected/known-first (Model.sortWifiRows); the list is
  // capped to this many rows tall and scrolls for the rest.
  readonly property int visibleRowCount: 5
  // Set by WifiSection to grow the list to match the Ethernet column's
  // height in two-column mode.
  property real extraHeight: 0
  readonly property real listSpacing: Style.space(8)
  readonly property real listRowEstimate: Style.font.bodySmall + Style.font.caption + Style.space(1) + listSpacing
  readonly property real listNaturalHeight: Math.min(networkListView.contentHeight, listRowEstimate * visibleRowCount - listSpacing)
  readonly property real listRenderHeight: Math.min(networkListView.contentHeight, listNaturalHeight + extraHeight)
  // This component's height with no stretch applied (used by WifiSection).
  readonly property real unstretchedImplicitHeight: wifiNetworks.length === 0
    ? sectionHeaderItem.implicitHeight + column.spacing + emptyStateText.implicitHeight
    : sectionHeaderItem.implicitHeight + column.spacing + listNaturalHeight

  // Per-row in-flight state: at most one action at a time, tracked by SSID
  // so a row can render "Connecting…" / "Disconnecting…" / "Forgetting…".
  property string actionSsid: ""
  property string actionKind: ""  // "connect" | "disconnect" | "forget"
  property string failureSsid: ""
  property string failureReason: ""
  readonly property bool busy: actionKind !== ""

  // The row currently expanded into password-entry mode, tracked by SSID.
  property string passwordSsid: ""
  property string passwordText: ""
  // Set/cleared by the open row delegate's TextField.
  property bool passwordFieldHasFocus: false
  readonly property bool anyFieldFocused: passwordSsid !== "" && passwordFieldHasFocus

  readonly property var connectionFailReasons: ({
    NoSecrets: ConnectionFailReason.NoSecrets,
    WifiAuthTimeout: ConnectionFailReason.WifiAuthTimeout,
    WifiNetworkLost: ConnectionFailReason.WifiNetworkLost,
    WifiClientDisconnected: ConnectionFailReason.WifiClientDisconnected,
    WifiClientFailed: ConnectionFailReason.WifiClientFailed
  })

  implicitWidth: column.implicitWidth
  implicitHeight: column.implicitHeight

  // Tracks which device this instance turned scanning on for, so it can
  // release exactly that one.
  property var scannerDevice: null

  function setScannerEnabled(enabled) {
    var nextDevice = root.active ? root.device : null
    if (scannerDevice && scannerDevice !== nextDevice) scannerDevice.scannerEnabled = false
    scannerDevice = nextDevice
    if (scannerDevice) scannerDevice.scannerEnabled = enabled
  }

  Component.onDestruction: if (scannerDevice) scannerDevice.scannerEnabled = false

  onActiveChanged: {
    setScannerEnabled(active)
    // Resets scroll position to the top on reopen.
    if (active) Qt.callLater(function() { networkListView.positionViewAtBeginning() })
  }
  onDeviceChanged: setScannerEnabled(root.active)
  onNetworkObjectsChanged: syncWifiNetworks()

  function syncWifiNetworks() {
    var networks = networkObjects || []
    var nets = []
    for (var i = 0; i < networks.length; i++) {
      var network = networks[i]
      if (!network) continue
      checkActionCompletion(network)
      var row = Model.wifiRow(network)
      if (row) nets.push(row)
    }
    wifiNetworks = Model.sortWifiRows(nets)
  }

  onWifiNetworksChanged: {
    // Closes the password field if its network drops out of the scan.
    if (passwordSsid !== "" && wifiIndexForSsid(passwordSsid) < 0) passwordSsid = ""
  }

  function networkForSsid(ssid) {
    var networks = networkObjects || []
    for (var i = 0; i < networks.length; i++) {
      if (networks[i] && networks[i].name === ssid) return networks[i]
    }
    return null
  }

  function wifiIndexForSsid(ssid) {
    for (var i = 0; i < wifiNetworks.length; i++) {
      if (wifiNetworks[i] && wifiNetworks[i].ssid === ssid) return i
    }
    return -1
  }

  function requiresCredentials(security) {
    return Model.requiresCredentials(security, WifiSecurityType.Open, WifiSecurityType.Owe)
  }

  function canForgetNetwork(net) {
    return Model.canForgetNetwork(net)
  }

  function openPasswordPrompt(ssid) {
    if (passwordSsid !== ssid) passwordText = ""
    passwordSsid = ssid
  }

  function cancelPasswordPrompt() {
    passwordSsid = ""
    passwordText = ""
  }

  function runNetworkAction(kind, network, callback) {
    if (actionKind !== "" || !network) return
    actionSsid = network.name || ""
    actionKind = kind
    failureSsid = ""
    failureReason = ""
    callback(network)
    actionTimeout.restart()
  }

  function clearNetworkAction() {
    actionTimeout.stop()
    if (actionKind === "connect") passwordSsid = ""
    failureSsid = ""
    failureReason = ""
    actionSsid = ""
    actionKind = ""
  }

  function failNetworkAction(network, reason) {
    if (!network || actionKind === "" || actionSsid !== (network.name || "")) return
    actionTimeout.stop()
    failureSsid = actionSsid
    failureReason = Model.networkFailureReason(reason, requiresCredentials(network.security), connectionFailReasons)
    actionSsid = ""
    actionKind = ""
  }

  function checkActionCompletion(network) {
    if (!network || actionKind === "" || actionSsid !== (network.name || "")) return
    if (actionKind === "connect" && network.connected) clearNetworkAction()
    else if (actionKind === "disconnect" && !network.connected && !network.stateChanging) clearNetworkAction()
    else if (actionKind === "forget" && !network.known && !network.stateChanging) clearNetworkAction()
  }

  function connectDirectly(ssid) {
    runNetworkAction("connect", networkForSsid(ssid), function(network) { network.connect() })
  }

  function connectWithPassphrase(ssid, passphrase) {
    runNetworkAction("connect", networkForSsid(ssid), function(network) { network.connectWithPsk(passphrase) })
  }

  function disconnectRow(ssid) {
    var network = networkForSsid(ssid)
    if (network) runNetworkAction("disconnect", network, function(net) { net.disconnect() })
  }

  function forgetRow(ssid) {
    runNetworkAction("forget", networkForSsid(ssid), function(network) { network.forget() })
  }

  // connected -> disconnect; needs credentials -> password prompt; else connect.
  function activateRow(net) {
    if (busy || !net) return
    if (net.connected) { disconnectRow(net.ssid); return }
    if (requiresCredentials(net.security) && !net.known) { openPasswordPrompt(net.ssid); return }
    connectDirectly(net.ssid)
  }

  Timer {
    id: actionTimeout
    interval: 30000
    repeat: false
    onTriggered: {
      if (!root.actionKind) return
      var reason = root.actionKind === "connect" ? "Timed out connecting"
        : root.actionKind === "disconnect" ? "Timed out disconnecting" : "Timed out forgetting"
      root.failureSsid = root.actionSsid
      root.failureReason = reason
      root.actionSsid = ""
      root.actionKind = ""
    }
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      id: sectionHeaderItem
      text: {
        if (!Networking.wifiEnabled) return "NEARBY NETWORKS"
        if (root.device && root.device.scannerEnabled && root.wifiNetworks.length === 0) return "NEARBY NETWORKS (SCANNING…)"
        if (root.wifiNetworks.length > root.visibleRowCount) return "NEARBY NETWORKS (" + root.wifiNetworks.length + ")"
        return "NEARBY NETWORKS"
      }
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    Text {
      id: emptyStateText
      textFormat: Text.PlainText
      visible: root.wifiNetworks.length === 0
      text: !Networking.wifiEnabled ? "Wi-Fi is off." : (root.device ? "Scanning for networks…" : "No Wi-Fi adapter.")
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    ListView {
      id: networkListView
      width: parent.width
      height: root.listRenderHeight
      spacing: root.listSpacing
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      visible: root.wifiNetworks.length > 0

      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      model: root.wifiNetworks

      delegate: Item {
        id: rowWrap
        required property var modelData
        required property int index
        width: ListView.view.width
        height: rowColumn.implicitHeight

        readonly property var net: modelData
        readonly property bool needsCredentials: root.requiresCredentials(net.security) && !net.known
        readonly property bool canForget: root.canForgetNetwork(net)
        readonly property bool isBusy: root.actionKind !== "" && root.actionSsid === net.ssid
        readonly property bool isFailed: root.failureReason !== "" && root.failureSsid === net.ssid
        readonly property bool isPasswordOpen: root.passwordSsid === net.ssid
        readonly property bool hasCursor: root.cursorIndex === index

        Rectangle {
          anchors.fill: rowColumn
          anchors.margins: -Style.space(6)
          radius: Style.cornerRadius
          visible: rowWrap.hasCursor
          color: Style.hoverFillFor(root.bar.foreground, Color.accent)
        }

        readonly property string subtitle: {
          if (isBusy) {
            if (root.actionKind === "connect") return "Connecting…"
            if (root.actionKind === "disconnect") return "Disconnecting…"
            return "Forgetting…"
          }
          if (isFailed) return root.failureReason
          if (net.connected) return "Connected"
          if (net.known) return "Saved"
          return ""
        }

        Connections {
          target: root.networkForSsid(rowWrap.net.ssid)
          function onConnectionFailed(reason) {
            var ours = root.actionKind === "connect" && root.actionSsid === rowWrap.net.ssid
            root.failNetworkAction(root.networkForSsid(rowWrap.net.ssid), reason)
            if (ours && Model.shouldRepromptPassphrase(reason, rowWrap.needsCredentials || root.requiresCredentials(rowWrap.net.security), root.connectionFailReasons))
              root.openPasswordPrompt(rowWrap.net.ssid)
          }
        }

        Column {
          id: rowColumn
          width: parent.width
          spacing: Style.space(6)

        Item {
          width: parent.width
          implicitHeight: Math.max(icon.implicitHeight, labels.implicitHeight, actions.implicitHeight)

          Text {
            id: icon
            textFormat: Text.PlainText
            text: Model.wifiIconFor(rowWrap.net.signal)
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Row {
            id: actions
            spacing: Style.space(4)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            PanelActionButton {
              visible: rowWrap.needsCredentials
              iconText: "󰌾"
              tooltipText: "Requires a password"
              foreground: Qt.darker(root.bar.foreground, 1.4)
              fontFamily: root.bar.fontFamily
              enabled: false
            }

            PanelActionButton {
              visible: rowWrap.canForget
              iconText: "󰅙"
              tooltipText: "Forget network"
              foreground: root.bar.foreground
              hoverColor: root.bar.urgent
              fontFamily: root.bar.fontFamily
              enabled: !root.busy
              onClicked: root.forgetRow(rowWrap.net.ssid)
            }
          }

          Column {
            id: labels
            anchors.left: icon.right
            anchors.leftMargin: Style.space(10)
            anchors.right: actions.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              text: rowWrap.net.ssid || "(hidden network)"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: rowWrap.net.connected
              elide: Text.ElideRight
              width: parent.width
            }
            Text {
              textFormat: Text.PlainText
              visible: rowWrap.subtitle !== ""
              text: rowWrap.subtitle
              color: rowWrap.isFailed ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }

          MouseArea {
            anchors.left: parent.left
            anchors.right: actions.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            enabled: !root.busy
            cursorShape: Qt.PointingHandCursor
            onClicked: root.activateRow(rowWrap.net)
          }
        }

        Item {
          id: passwordClip
          width: parent.width
          clip: true
          height: rowWrap.isPasswordOpen ? passwordForm.implicitHeight : 0
          visible: height > 0

          Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

          Connections {
            target: rowWrap
            function onIsPasswordOpenChanged() {
              if (rowWrap.isPasswordOpen) Qt.callLater(function() { passwordInput.forceActiveFocus() })
            }
          }

          Row {
            id: passwordForm
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: passwordInput
              width: parent.width - connectBtn.width - cancelBtn.width - parent.spacing * 2
              placeholderText: "Password"
              echoMode: TextInput.Password
              font.pixelSize: Style.font.bodySmall
              foreground: root.bar.foreground
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              text: rowWrap.isPasswordOpen ? root.passwordText : ""
              onTextChanged: if (rowWrap.isPasswordOpen) root.passwordText = text
              onAccepted: if (root.passwordText.length > 0) root.connectWithPassphrase(rowWrap.net.ssid, root.passwordText)
              onActiveFocusChanged: root.passwordFieldHasFocus = activeFocus
              Keys.onEscapePressed: root.cancelPasswordPrompt()
            }

            PanelActionButton {
              id: connectBtn
              iconText: "󰄬"
              tooltipText: "Connect"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              enabled: root.passwordText.length > 0 && !root.busy
              onClicked: root.connectWithPassphrase(rowWrap.net.ssid, root.passwordText)
            }

            PanelActionButton {
              id: cancelBtn
              iconText: "󰅙"
              tooltipText: "Cancel"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.cancelPasswordPrompt()
            }
          }
        }
        }
      }
    }
  }
}
