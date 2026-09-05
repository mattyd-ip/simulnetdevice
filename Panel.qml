import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons

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

  // Bar icon currently mirrors Ethernet alone; becomes a real priority rule
  // between both sections once WifiSection lands.
  readonly property string icon: ethernetSection.icon
  readonly property real iconOpacity: ethernetSection.iconOpacity

  visible: ethernetSection.hasAdapter
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

        EthernetSection {
          id: ethernetSection
          width: parent.width
          bar: root.bar
          opened: root.opened
        }
      }
    }
  }
}
