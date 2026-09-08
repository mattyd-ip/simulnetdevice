import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar icon + popup shell for SimulNetDevice. Wi-Fi and Ethernet each get
// their own self-contained section component (EthernetSection.qml,
// WifiSection.qml) that queries its own interface directly rather than
// the default route.
Panel {
  id: root
  moduleName: "simulnetdevice"
  ipcTarget: "simulnetdevice"
  manageIpc: false

  // Bar icon: primary interface's icon when both are connected, else
  // whichever is connected, else Wi-Fi's icon.
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

  // ---------- Keyboard cursor ----------
  // Both sections expose `navGroupIds`, `navGroupCount(id)`,
  // `navActivate(id, item)`, `navDelete(id, item)`. This is where
  // h/j/k/l/space/enter/x turn into index math over those groups.
  //
  // j/k move between groups within the current section, spilling into the
  // other section at the top/bottom edge while stacked (single column).
  // h/l move between items within a group, spilling into the other column
  // at the left/right edge while side by side.
  property bool cursorActive: false
  property string cursorSection: "wifi"  // "wifi" | "ethernet"
  property int cursorGroup: 0
  property int cursorItem: 0

  function sectionFor(name) { return name === "wifi" ? wifiSection : ethernetSection }

  // Clamps cursorGroup/cursorItem to the current section's group/item counts.
  function clampCursorToSection(name) {
    var ids = sectionFor(name).navGroupIds
    if (ids.length === 0) { root.cursorGroup = 0; root.cursorItem = 0; return }
    root.cursorGroup = Math.max(0, Math.min(root.cursorGroup, ids.length - 1))
    var count = sectionFor(name).navGroupCount(ids[root.cursorGroup])
    root.cursorItem = Math.max(0, Math.min(root.cursorItem, Math.max(0, count - 1)))
  }

  function moveCursor(dx, dy) {
    root.cursorActive = true
    root.clampCursorToSection(root.cursorSection)
    var ids = sectionFor(root.cursorSection).navGroupIds
    if (ids.length === 0) return

    if (dy !== 0) {
      var nextGroup = root.cursorGroup + dy
      if (nextGroup < 0 || nextGroup >= ids.length) {
        if (!panel.twoColumn) {
          // Wi-Fi renders above Ethernet when stacked. Crossing sections
          // lands on the far edge group of the other section, item 0.
          if (dy > 0 && root.cursorSection === "wifi" && ethernetSection.navGroupIds.length > 0) {
            root.cursorSection = "ethernet"
            root.cursorGroup = 0
            root.cursorItem = 0
            root.clampCursorToSection(root.cursorSection)
            return
          }
          if (dy < 0 && root.cursorSection === "ethernet" && wifiSection.navGroupIds.length > 0) {
            root.cursorSection = "wifi"
            root.cursorGroup = wifiSection.navGroupIds.length - 1
            root.cursorItem = 0
            root.clampCursorToSection(root.cursorSection)
            return
          }
        }
        return // clamp: nothing further that way
      }
      root.cursorGroup = nextGroup
      root.clampCursorToSection(root.cursorSection)
      return
    }

    if (dx !== 0) {
      var count = sectionFor(root.cursorSection).navGroupCount(ids[root.cursorGroup])
      var nextItem = root.cursorItem + dx
      if (nextItem < 0 || nextItem >= count) {
        if (panel.twoColumn) {
          // Wi-Fi is the left column, Ethernet the right. Crossing columns
          // lands on the same group id if the destination section has one,
          // else on the "hero" group.
          var fromId = ids[root.cursorGroup]
          var toSection = (dx > 0 && root.cursorSection === "wifi") ? "ethernet"
            : (dx < 0 && root.cursorSection === "ethernet") ? "wifi" : ""
          if (toSection !== "") {
            var newIds = sectionFor(toSection).navGroupIds
            var matchIdx = newIds.indexOf(fromId)
            root.cursorSection = toSection
            root.cursorGroup = matchIdx >= 0 ? matchIdx : Math.max(0, newIds.indexOf("hero"))
            var destCount = sectionFor(toSection).navGroupCount(newIds[root.cursorGroup])
            root.cursorItem = dx > 0 ? 0 : Math.max(0, destCount - 1)
            root.clampCursorToSection(root.cursorSection)
          }
        }
        return // clamp
      }
      root.cursorItem = nextItem
    }
  }

  function activateCursor() {
    if (!root.cursorActive) return
    root.clampCursorToSection(root.cursorSection)
    var ids = sectionFor(root.cursorSection).navGroupIds
    if (ids.length === 0) return
    sectionFor(root.cursorSection).navActivate(ids[root.cursorGroup], root.cursorItem)
  }

  function deleteCursor() {
    if (!root.cursorActive) return
    root.clampCursorToSection(root.cursorSection)
    var ids = sectionFor(root.cursorSection).navGroupIds
    if (ids.length === 0) return
    sectionFor(root.cursorSection).navDelete(ids[root.cursorGroup], root.cursorItem)
  }

  // Cursor resets to inactive/wifi/0/0 on close; refreshes the conflict
  // check on open.
  onOpenedChanged: {
    if (!root.opened) {
      root.cursorActive = false
      root.cursorSection = "wifi"
      root.cursorGroup = 0
      root.cursorItem = 0
    } else {
      root.refreshConflictCheck()
    }
  }

  // ---------- omarchy.network conflict notice ----------
  property var conflictInfo: ({})
  readonly property bool conflictNoticeDismissed: conflictInfo.dismissed === "1"
  readonly property bool showConflictNotice: conflictInfo.enabled === "true" && !root.conflictNoticeDismissed
  readonly property bool conflictCanDisable: conflictInfo.canDisable === "true"

  readonly property string conflictCheckScript:
    "enabled=$(omarchy plugin list --json | jq -r '.[] | select(.id==\"omarchy.network\") | .enabled')\n" +
    "can_disable=$(omarchy plugin list --json | jq -r '.[] | select(.id==\"omarchy.network\") | .canDisable')\n" +
    "dismissed=0\n" +
    "[[ -f \"$HOME/.config/simulnetdevice/hide-network-conflict-notice\" ]] && dismissed=1\n" +
    "printf 'enabled\\t%s\\n' \"${enabled:-false}\"\n" +
    "printf 'canDisable\\t%s\\n' \"${can_disable:-false}\"\n" +
    "printf 'dismissed\\t%s\\n' \"$dismissed\"\n"

  function refreshConflictCheck() {
    if (conflictCheckProc.running) return
    conflictCheckProc.command = ["bash", "-c", root.conflictCheckScript]
    conflictCheckProc.running = true
  }

  Process {
    id: conflictCheckProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.conflictInfo = Model.parseKeyValue(text) }
  }

  function disableNetworkWidget() {
    if (disableNetworkProc.running) return
    disableNetworkProc.command = ["omarchy", "plugin", "disable", "omarchy.network"]
    disableNetworkProc.running = true
  }

  Process {
    id: disableNetworkProc
    onExited: root.refreshConflictCheck()
  }

  // Writes ~/.config/simulnetdevice/hide-network-conflict-notice.
  function dismissConflictNotice() {
    if (dismissConflictProc.running) return
    dismissConflictProc.command = ["bash", "-c",
      "mkdir -p \"$HOME/.config/simulnetdevice\" && touch \"$HOME/.config/simulnetdevice/hide-network-conflict-notice\""]
    dismissConflictProc.running = true
  }

  Process {
    id: dismissConflictProc
    onExited: root.refreshConflictCheck()
  }

  IpcHandler {
    target: "simulnetdevice"
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

    readonly property real columnWidth: Style.space(380)
    readonly property real columnGap: Style.space(16)
    // Two columns only while both Wi-Fi and Ethernet are connected.
    readonly property bool twoColumn: wifiSection.isConnected && ethernetSection.isConnected

    contentWidth: panel.fittedContentWidth(panel.twoColumn ? panel.columnWidth * 2 + panel.columnGap : panel.columnWidth)
    contentHeight: panel.fittedContentHeight(popupColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Blocked while a text field (static-IP or Wi-Fi password) is focused.
      blocked: ethernetSection.anyFieldFocused || wifiSection.anyFieldFocused
      // Reclaims keyboard focus once nothing is blocked.
      onBlockedChanged: if (!blocked) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteCursor()

      Column {
        id: popupColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        Rectangle {
          id: conflictBanner
          visible: root.showConflictNotice
          width: parent.width
          height: visible ? bannerContent.implicitHeight + Style.space(16) : 0
          radius: Style.cornerRadius
          color: Style.hoverFillFor(root.bar.foreground, Color.accent)
          clip: true

          Column {
            id: bannerContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(8)
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: "The built-in Network widget is also enabled. Running both at once can briefly stop Wi-Fi scanning in whichever popup you leave open, since they share one scan toggle."
              wrapMode: Text.WordWrap
              width: parent.width
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: "Disable it"
                visible: root.conflictCanDisable
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                onClicked: root.disableNetworkWidget()
              }

              Button {
                text: "Keep both"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                onClicked: root.dismissConflictNotice()
              }
            }

            Text {
              textFormat: Text.PlainText
              text: root.conflictCanDisable
                ? "Or from a terminal: omarchy plugin disable omarchy.network"
                : "This system won't let plugins disable it from here -- from a terminal: omarchy plugin disable omarchy.network"
              wrapMode: Text.WordWrap
              width: parent.width
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // columns switches between 1 (stacked) and 2 (side by side).
        Grid {
          id: sectionsGrid
          width: parent.width
          columns: panel.twoColumn ? 2 : 1
          columnSpacing: panel.columnGap
          rowSpacing: Style.space(16)

          WifiSection {
            id: wifiSection
            width: panel.twoColumn ? (sectionsGrid.width - sectionsGrid.columnSpacing) / 2 : sectionsGrid.width
            bar: root.bar
            opened: root.opened
            // Ethernet's routeMetric while Ethernet is connected, else undefined.
            primaryCompareMetric: ethernetSection.isConnected ? ethernetSection.routeMetric : undefined
            onRouteMetricApplied: ethernetSection.setRouteMetric(Model.SECONDARY_METRIC)
            // Grows to match Ethernet's height in two-column mode.
            stretchTargetHeight: panel.twoColumn ? ethernetSection.implicitHeight : 0
            // -1 while the cursor belongs to the other section.
            cursorActive: root.cursorActive
            cursorGroup: root.cursorSection === "wifi" ? root.cursorGroup : -1
            cursorItem: root.cursorItem
          }

          PanelSeparator {
            visible: !panel.twoColumn
            width: sectionsGrid.width
            foreground: root.bar.foreground
          }

          EthernetSection {
            id: ethernetSection
            width: panel.twoColumn ? (sectionsGrid.width - sectionsGrid.columnSpacing) / 2 : sectionsGrid.width
            bar: root.bar
            opened: root.opened
            // See WifiSection's identical comment.
            primaryCompareMetric: wifiSection.isConnected ? wifiSection.routeMetric : undefined
            onRouteMetricApplied: wifiSection.setRouteMetric(Model.SECONDARY_METRIC)
            // See WifiSection's identical comment.
            cursorActive: root.cursorActive
            cursorGroup: root.cursorSection === "ethernet" ? root.cursorGroup : -1
            cursorItem: root.cursorItem
          }
        }
      }
    }
  }
}
