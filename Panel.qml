import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.ecylmz.omarchy-tunnel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property int cursorIndex: 0
  property bool cursorActive: false
  property string pendingDeleteUuid: ""

  readonly property int activeCount: tunnel.activeCount
  readonly property bool available: tunnel.available
  readonly property var profiles: tunnel.profiles
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int actionIndex: profiles.length

  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function refresh() {
    tunnel.refresh()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = Math.max(0, Math.min(actionIndex, index))
    pendingDeleteUuid = ""
  }

  function moveCursor(dy) {
    if (dy === 0) return
    if (!cursorActive) {
      cursorActive = true
      return
    }
    setCursor(cursorIndex + dy)
  }

  function activateCursor() {
    if (!cursorActive) return
    if (cursorIndex === actionIndex) {
      importDialog.open()
      return
    }
    var profile = profiles[cursorIndex]
    if (profile) tunnel.toggleProfile(profile.uuid)
  }

  function requestDelete(uuid) {
    var profile = tunnel.profileByUuid(uuid)
    if (!profile) return
    if (profile.active) {
      tunnel.fail("Disconnect the tunnel before removing it")
      return
    }
    if (pendingDeleteUuid === uuid) {
      pendingDeleteUuid = ""
      tunnel.removeProfile(uuid)
    } else {
      pendingDeleteUuid = uuid
      tunnel.flash("Press remove again to confirm")
    }
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    pendingDeleteUuid = ""
    tunnel.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onProfilesChanged: {
    if (cursorIndex > actionIndex) cursorIndex = actionIndex
    if (pendingDeleteUuid !== "" && !tunnel.profileByUuid(pendingDeleteUuid)) pendingDeleteUuid = ""
  }

  Service {
    id: tunnel
  }

  FileDialog {
    id: importDialog
    title: "Import WireGuard configuration"
    fileMode: FileDialog.OpenFile
    nameFilters: ["WireGuard configuration (*.conf *.wg)", "All files (*)"]
    onAccepted: tunnel.importConfig(selectedFile)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "i" || t === "I") importDialog.open()
        else if (t === "r" || t === "R") tunnel.refresh()
        else if ((t === "d" || t === "D") && root.cursorIndex < root.profiles.length) {
          var profile = root.profiles[root.cursorIndex]
          if (profile) root.requestDelete(profile.uuid)
        }
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Omarchy Tunnel"
            meta: !tunnel.probed ? "Checking NetworkManager…"
              : !tunnel.available ? "NetworkManager unavailable"
              : tunnel.activeCount > 0 ? tunnel.activeCount + " active tunnel" + (tunnel.activeCount === 1 ? "" : "s")
              : tunnel.profiles.length > 0 ? "Disconnected"
              : "No WireGuard profiles"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: tunnel.activeCount > 0 ? 1.0 : 0.55
            iconComponent: Component {
              Text {
                text: tunnel.activeCount > 0 ? "\uf023" : "\uf09c"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: tunnel.actionStatus !== "" || tunnel.lastError !== ""
            width: parent.width
            text: tunnel.actionStatus !== "" ? tunnel.actionStatus : tunnel.lastError
            color: tunnel.lastError !== "" && tunnel.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            visible: tunnel.available && root.profiles.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "WIREGUARD"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.profiles

              ProfileRow {
                required property var modelData
                required property int index
                width: parent.width
                profile: modelData
                rowIndex: index
              }
            }
          }

          Text {
            visible: tunnel.available && root.profiles.length === 0
            width: parent.width
            text: "Import a WireGuard .conf file to get started."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            visible: tunnel.available
            foreground: root.foreground
          }

          ImportRow {
            visible: tunnel.available
            width: parent.width
          }

          Text {
            visible: tunnel.available
            width: parent.width
            text: "No passwordless sudo. Connections are managed by NetworkManager and authorized through its normal policy."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component ProfileRow: CursorSurface {
    id: row
    property var profile: null
    property int rowIndex: 0
    readonly property bool rowBusy: profile && tunnel.busyUuid === profile.uuid

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    current: profile && profile.active === true
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: inner.implicitHeight + Style.space(12)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: profile && !row.rowBusy && !tunnel.importing
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.setCursor(row.rowIndex)
      onClicked: if (profile) tunnel.toggleProfile(profile.uuid)
    }

    RowLayout {
      id: inner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: row.profile ? row.profile.name : "WireGuard"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.profile && row.profile.active
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: !row.profile ? ""
            : row.rowBusy ? (tunnel.actionKind === "up" ? "Connecting…" : tunnel.actionKind === "down" ? "Disconnecting…" : "Removing…")
            : row.profile.active ? "Connected" + (row.profile.device ? " · " + row.profile.device : "")
            : "Disconnected"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: row.profile && !row.profile.active
        iconText: root.pendingDeleteUuid === (row.profile ? row.profile.uuid : "") ? "\uf00c" : "\uf1f8"
        foreground: root.pendingDeleteUuid === (row.profile ? row.profile.uuid : "") ? root.urgent : root.foreground
        fontFamily: root.fontFamily
        enabled: !row.rowBusy && !tunnel.importing
        Layout.alignment: Qt.AlignVCenter
        onClicked: if (row.profile) root.requestDelete(row.profile.uuid)
      }

      ToggleSwitch {
        checked: row.profile ? row.profile.active : false
        busy: row.rowBusy
        foreground: root.foreground
        enabled: row.profile && !tunnel.importing
        Layout.alignment: Qt.AlignVCenter
        onHovered: function(on) { if (on) root.setCursor(row.rowIndex) }
        onToggled: if (row.profile) tunnel.toggleProfile(row.profile.uuid)
      }
    }
  }

  component ImportRow: CursorSurface {
    id: importRow
    hasCursor: root.cursorActive && root.cursorIndex === root.actionIndex
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: importInner.implicitHeight + Style.space(12)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: !tunnel.busy
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.setCursor(root.actionIndex)
      onClicked: importDialog.open()
    }

    RowLayout {
      id: importInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        text: "+"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: "Import configuration"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: "WireGuard .conf or .wg"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "\uf07c"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !tunnel.busy
        Layout.alignment: Qt.AlignVCenter
        onClicked: importDialog.open()
      }
    }
  }
}
