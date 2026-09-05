import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar icon + popup shell for netctl. Wi-Fi and Ethernet each get their own
// self-contained section component (EthernetSection.qml, WifiSection.qml)
// that query their own interface directly rather than the default route --
// that's the whole reason this plugin exists instead of the built-in
// omarchy.network widget, which only ever reports on whichever interface
// currently owns the default route and so hides one interface whenever
// both are connected at once.
Panel {
  id: root
  moduleName: "netctl"
  ipcTarget: "netctl"
  manageIpc: false

  // Bar icon: whichever interface is primary wins when both are connected;
  // otherwise whichever one is connected; otherwise Wi-Fi's icon (off/no
  // adapter) as the more common case to default to on a laptop.
  readonly property string icon: {
    if (ethernetSection.isConnected && wifiSection.isConnected) {
      return ethernetSection.isPrimary ? ethernetSection.icon : wifiSection.icon
    }
    if (ethernetSection.isConnected) return ethernetSection.icon
    return wifiSection.icon
  }
  readonly property real iconOpacity: (ethernetSection.isConnected || wifiSection.isConnected) ? 1.0 : 0.5

  visible: ethernetSection.hasAdapter || wifiSection.hasAdapter
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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
    // 380, not 340: matches the built-in network widget's popup width, which
    // is the proven-good fit for this same 4-column stats grid -- a narrower
    // popup let the "IP Address" label collide with its value (caught via a
    // real screenshot, not just qmllint/journalctl checks).
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Static-IP text fields own their own keys while focused -- h/j/k/l
      // and space are ordinary characters there.
      blocked: ethernetSection.anyFieldFocused
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(16)

        WifiSection {
          id: wifiSection
          width: parent.width
          bar: root.bar
          opened: root.opened
          // Cross-wired so each section's "Set primary" reflects the real
          // comparison against the other's actual metric, not a guess.
          primaryCompareMetric: ethernetSection.routeMetric
          onRouteMetricApplied: ethernetSection.setRouteMetric(Model.SECONDARY_METRIC)
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        EthernetSection {
          id: ethernetSection
          width: parent.width
          bar: root.bar
          opened: root.opened
          primaryCompareMetric: wifiSection.routeMetric
          onRouteMetricApplied: wifiSection.setRouteMetric(Model.SECONDARY_METRIC)
        }
      }
    }
  }
}
