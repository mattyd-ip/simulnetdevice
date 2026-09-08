import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar icon + popup shell for SimulNetDevice. Wi-Fi and Ethernet each get their own
// self-contained section component (EthernetSection.qml, WifiSection.qml)
// that query their own interface directly rather than the default route --
// that's the whole reason this plugin exists instead of the built-in
// omarchy.network widget, which only ever reports on whichever interface
// currently owns the default route and so hides one interface whenever
// both are connected at once.
Panel {
  id: root
  moduleName: "simulnetdevice"
  ipcTarget: "simulnetdevice"
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

  // ---------- Keyboard cursor ----------
  // Both sections expose the same small interface (see WifiSection's and
  // EthernetSection's own "Keyboard cursor" comment): `navGroupIds`, a
  // `navGroupCount(id)`/`navActivate(id, item)`/`navDelete(id, item)` triple.
  // This is the one place that turns h/j/k/l/space/enter/x into index math
  // over those groups -- neither section knows the other exists.
  //
  // j/k move between groups within the current section, spilling into the
  // other section at the top/bottom edge -- but only while stacked
  // (single column); side by side, each column scrolls on its own.
  // h/l move between items within a group, spilling into the other
  // *column* at the left/right edge -- but only while side by side, since
  // there is no horizontal neighbor when stacked.
  property bool cursorActive: false
  property string cursorSection: "wifi"  // "wifi" | "ethernet"
  property int cursorGroup: 0
  property int cursorItem: 0

  function sectionFor(name) { return name === "wifi" ? wifiSection : ethernetSection }

  // Defensive against the underlying list having shrunk (a scan losing a
  // row, a profile deleted, Wi-Fi disconnecting and dropping its "band"
  // group) since the cursor last moved -- called before every read below.
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
          // Wi-Fi renders above Ethernet when stacked -- see sectionsGrid.
          // Landing group is always the far edge (top/bottom) of the other
          // section, so the item resets to 0 too -- carrying over whatever
          // item index this section happened to be on would land on some
          // unrelated control in the other section's edge group.
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
          // Wi-Fi is the left column, Ethernet the right -- see sectionsGrid.
          // Prefer landing on the SAME group id (e.g. "hero" <-> "hero") so
          // crossing at a spatially-aligned row keeps you on it; fall back
          // to "hero" (not the same numeric group index) when there's no
          // such group -- e.g. Ethernet's profile rows have no Wi-Fi
          // counterpart, and clamping by raw index would land on whatever
          // Wi-Fi's *last* group happens to be, which is the nearby-network
          // list. That list's length changes on its own as scans complete,
          // so "the last row" stops being the actual last row within
          // moments and `l` can never find the edge to cross back out.
          // "hero" always exists in both sections and never resizes.
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

  // Fresh cursor every time the popup opens, hidden until the first
  // keypress -- a stale highlight from last time would otherwise reappear
  // on a control that may not even mean the same thing anymore.
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
  // The one real conflict between running both widgets at once: Wi-Fi
  // scanning is controlled by `WifiDevice.scannerEnabled`, a single flag
  // shared by every plugin that touches it, with no reference counting
  // across plugin instances (see WifiScanList.qml's identical comment, and
  // the built-in widget's own -- same design, same limitation). If both
  // popups are open together, whichever one closes first turns scanning
  // off for the other too, until it's reopened. Everything else either
  // widget does (route-metric writes, band pinning, status polling) goes
  // through nmcli against NetworkManager's own state, which is the single
  // source of truth both just read back -- no actual corruption risk there.
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

  // "Keep both" -- remembered permanently (not just for this session), so
  // choosing to run both deliberately doesn't mean seeing this banner on
  // every single open. Nothing else in SimulNetDevice reads this marker; deleting
  // ~/.config/simulnetdevice/hide-network-conflict-notice brings the notice back.
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

    // 380, not 340: matches the built-in network widget's popup width, which
    // is the proven-good fit for this same 4-column stats grid -- a narrower
    // popup let the "IP Address" label collide with its value (caught via a
    // real screenshot, not just qmllint/journalctl checks).
    readonly property real columnWidth: Style.space(380)
    readonly property real columnGap: Style.space(16)
    // Wi-Fi and Ethernet each get their own column, side by side, only while
    // both are actually connected -- keyed on isConnected rather than mere
    // adapter presence so switching Ethernet off (still physically present,
    // just disconnected) drops back to a single column instead of leaving
    // an idle column sitting there. A device with only one adapter never
    // gets that side connected in the first place, so it naturally stays
    // single-column too.
    readonly property bool twoColumn: wifiSection.isConnected && ethernetSection.isConnected

    contentWidth: panel.fittedContentWidth(panel.twoColumn ? panel.columnWidth * 2 + panel.columnGap : panel.columnWidth)
    contentHeight: panel.fittedContentHeight(popupColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Static-IP and Wi-Fi-password text fields own their own keys while
      // focused -- h/j/k/l and space are ordinary characters there.
      blocked: ethernetSection.anyFieldFocused || wifiSection.anyFieldFocused
      // A field closing (Escape, or Enter submitting it) doesn't hand
      // keyboard focus back to anything -- Qt Quick doesn't clear it just
      // because the field became invisible, so it's left pointed at a
      // hidden TextField that swallows every key silently. Reclaiming focus
      // here the moment nothing is blocked anymore is what lets h/j/k/l
      // work again without having to close and reopen the whole popup.
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

        // A Grid, not a Column: switching `columns` between 1 and 2 gives
        // us the single-stack and side-by-side layouts from the same two
        // section instances, with no duplication or manual reparenting.
        // Positioners skip invisible children entirely, so the separator
        // below drops out of the flow on its own in two-column mode
        // instead of leaving a gap.
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
            // Cross-wired so each section's "Set primary" reflects the
            // real comparison against the other's actual metric, not a
            // guess -- but only while the other is actually connected. A
            // disabled interface's last-saved metric is stale and
            // shouldn't get to outrank the one interface that's actually
            // up: Model.isPrimary already treats a non-finite compare
            // value as "nothing to compete with, so I'm primary by
            // default" -- undefined here (not ethernetSection.routeMetric)
            // is what triggers that.
            primaryCompareMetric: ethernetSection.isConnected ? ethernetSection.routeMetric : undefined
            onRouteMetricApplied: ethernetSection.setRouteMetric(Model.SECONDARY_METRIC)
            // Let the nearby-networks list grow to match Ethernet's height
            // in two-column mode -- Ethernet's own height never depends on
            // Wi-Fi's, so this direction is safe from binding loops.
            stretchTargetHeight: panel.twoColumn ? ethernetSection.implicitHeight : 0
            // -1 whenever the cursor belongs to the other section, so
            // every hasCursor binding inside WifiSection naturally reads
            // false.
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
