import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Saved static-IP profiles: name a set of address/gateway/DNS values once,
// re-apply it later instead of retyping it for every network that needs a
// fixed IP. Storage lives outside the plugin's own repo/symlink target, at
// ~/.config/netctl/profiles.json, via Quickshell.Io.FileView (path/
// watchChanges/text()/setText() -- confirmed API by reading the real
// FileView.qml wrapper and quickshell-io.qmltypes).
Item {
  id: root

  required property QtObject bar
  // Current static-IP form values, read when saving a new profile.
  property string currentAddress: ""
  property string currentGateway: ""
  property string currentDns: ""
  // Fired when the user picks a profile to apply -- the caller (Ethernet
  // section) fills its form fields but does not apply to nmcli until its
  // own Apply button is clicked, same as picking Static fresh.
  signal applyRequested(var profile)

  property var profiles: []
  property bool addingProfile: false
  // Exposed so the owning popup's PanelKeyCatcher can block h/j/k/l-as-
  // navigation while the profile-name field is focused.
  readonly property bool anyFieldFocused: addingProfile && nameInput.activeFocus

  // Row/item under the keyboard cursor (item 0 = Apply, 1 = Delete), or -1
  // (set by EthernetSection from Panel.qml's central cursor controller).
  property int cursorRowIndex: -1
  property int cursorRowItem: -1
  property bool addToggleHasCursor: false

  function applyByIndex(i) {
    var profile = profiles[i]
    if (profile) applyRequested(profile)
  }
  function deleteByIndex(i) { deleteProfileAt(i) }
  function startAdding() {
    root.addingProfile = true
    Qt.callLater(function() { nameInput.forceActiveFocus() })
  }

  implicitWidth: column.implicitWidth
  implicitHeight: column.implicitHeight

  readonly property string profilesPath: (Quickshell.env("HOME") || "") + "/.config/netctl/profiles.json"

  FileView {
    id: file
    path: root.profilesPath
    watchChanges: true
    onLoaded: root.profiles = Model.loadProfiles(text())
    onLoadFailed: function(error) { root.profiles = [] }
    onFileChanged: reload()
  }

  // FileView doesn't create missing parent directories on its own.
  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", (Quickshell.env("HOME") || "") + "/.config/netctl"]
  }

  function persist() {
    if (!ensureDirProc.running) ensureDirProc.running = true
    file.setText(Model.serializeProfiles(root.profiles))
  }

  function saveCurrentAs(name) {
    if (!Model.validateProfileName(name)) return
    var next = root.profiles.slice()
    next.push({
      name: name.trim(),
      address: root.currentAddress,
      gateway: root.currentGateway,
      dns: root.currentDns
    })
    root.profiles = next
    persist()
    addingProfile = false
    nameInput.text = ""
  }

  function deleteProfileAt(index) {
    if (index < 0 || index >= root.profiles.length) return
    var next = root.profiles.slice()
    next.splice(index, 1)
    root.profiles = next
    persist()
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: "SAVED ETHERNET PROFILES"
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    Text {
      textFormat: Text.PlainText
      visible: root.profiles.length === 0 && !root.addingProfile
      text: "No saved profiles yet."
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Repeater {
      model: root.profiles

      delegate: Item {
        required property var modelData
        required property int index
        width: column.width
        height: row.implicitHeight

        Item {
          id: row
          anchors.left: parent.left
          anchors.right: parent.right
          implicitHeight: Math.max(labels.implicitHeight, applyBtn.implicitHeight)

          Column {
            id: labels
            anchors.left: parent.left
            anchors.right: rowActions.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              text: modelData.name || ""
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width
            }
            Text {
              textFormat: Text.PlainText
              text: Model.profileSummary(modelData)
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: rowActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Button {
              id: applyBtn
              text: "Apply"
              fontSize: Style.font.caption
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              hasCursor: root.cursorRowIndex === index && root.cursorRowItem === 0
              onClicked: root.applyRequested(modelData)
            }

            PanelActionButton {
              iconText: "󰅙"
              tooltipText: "Delete profile"
              foreground: root.bar.foreground
              hoverColor: root.bar.urgent
              fontFamily: root.bar.fontFamily
              hasCursor: root.cursorRowIndex === index && root.cursorRowItem === 1
              onClicked: root.deleteProfileAt(index)
            }
          }
        }
      }
    }

    // Collapsing "save current as" row -- a Button that expands into a name
    // field, same clip/animate pattern as the static-IP form's own reveal.
    Item {
      id: addClip
      width: parent.width
      clip: true
      height: root.addingProfile ? addForm.implicitHeight : addToggle.implicitHeight

      Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

      Button {
        id: addToggle
        visible: !root.addingProfile
        text: "Save current as…"
        fontSize: Style.font.bodySmall
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        bordered: true
        width: parent.width
        enabled: Model.isValidCidr(root.currentAddress)
        hasCursor: root.addToggleHasCursor
        onClicked: root.startAdding()
      }

      Row {
        id: addForm
        visible: root.addingProfile
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: nameInput
          width: parent.width - saveBtn.width - cancelBtn.width - parent.spacing * 2
          placeholderText: "Profile name (e.g. Office LAN)"
          font.pixelSize: Style.font.bodySmall
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlGap
          verticalPadding: Style.spacing.controlPaddingY
          onAccepted: root.saveCurrentAs(text)
          Keys.onEscapePressed: { root.addingProfile = false; text = "" }
        }

        PanelActionButton {
          id: saveBtn
          iconText: "󰄬"
          tooltipText: "Save"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          enabled: Model.validateProfileName(nameInput.text)
          onClicked: root.saveCurrentAs(nameInput.text)
        }

        PanelActionButton {
          id: cancelBtn
          iconText: "󰅙"
          tooltipText: "Cancel"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onClicked: { root.addingProfile = false; nameInput.text = "" }
        }
      }
    }
  }
}
