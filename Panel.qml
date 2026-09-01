pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "ecylmz.omarchy-tunnel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property int cursorIndex: 0
  property bool cursorActive: false
  property string pendingDeleteUuid: ""
  property bool pickerOpen: false
  property int pickerIndex: 0

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
  readonly property string homeUrl: "file://" + String(Quickshell.env("HOME") || "/")
  readonly property var activeProfile: {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].active) return profiles[i]
    }
    return null
  }

  function open() {
    root.controller.show()
  }

  function close() {
    root.pickerOpen = false
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
      openPicker()
      return
    }
    var profile = profiles[cursorIndex]
    if (profile) tunnel.toggleProfile(profile.uuid)
  }

  function openPicker() {
    if (tunnel.busy) return
    pendingDeleteUuid = ""
    pickerIndex = 0
    pickerOpen = true
    folderModel.folder = root.homeUrl
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function closePicker() {
    pickerOpen = false
    pickerIndex = 0
    cursorActive = true
    cursorIndex = actionIndex
  }

  function pickerMove(dy) {
    if (dy === 0 || folderModel.count === 0) return
    cursorActive = true
    pickerIndex = Math.max(0, Math.min(folderModel.count - 1, pickerIndex + dy))
    scrollPickerCursorIntoView()
  }

  function pickerActivate() {
    if (folderModel.count === 0 || pickerIndex < 0 || pickerIndex >= folderModel.count) return
    var entryUrl = folderModel.get(pickerIndex, "fileUrl")
    if (folderModel.isFolder(pickerIndex)) {
      folderModel.folder = entryUrl
      pickerIndex = 0
      return
    }
    pickerOpen = false
    tunnel.importConfig(entryUrl)
  }

  function pickerGoParent() {
    var current = String(folderModel.folder)
    var parent = String(folderModel.parentFolder)
    if (parent === "" || parent === current) return
    folderModel.folder = folderModel.parentFolder
    pickerIndex = 0
  }

  function boundedLocalText(value, limit) {
    var maximum = Math.max(1, Math.min(Number(limit || 255), 512))
    var text = String(value || "").replace(/[\x00-\x1f\x7f]/g, "")
    return text.length > maximum ? text.substring(0, maximum - 1) + "…" : text
  }

  function pickerPathText() {
    var value = String(folderModel.folder || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { value = decodeURIComponent(value) } catch (e) {}
    var home = String(Quickshell.env("HOME") || "")
    if (home !== "" && value.indexOf(home) === 0) value = "~" + value.substring(home.length)
    return boundedLocalText(value === "" ? "/" : value, 512)
  }

  function scrollPickerCursorIntoView() {
    if (!pickerColumn || pickerIndex < 0 || pickerIndex >= pickerColumn.children.length) return
    var item = pickerColumn.children[pickerIndex]
    if (!item) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var margin = Style.space(6)
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
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
    pickerOpen = false
    pickerIndex = 0
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

  TunnelDetails {
    id: details
    profile: root.activeProfile
    pollingEnabled: root.opened && !root.pickerOpen
  }

  FolderListModel {
    id: folderModel
    folder: root.homeUrl
    nameFilters: ["*.conf", "*.wg"]
    showDirs: true
    showDirsFirst: true
    showDotAndDotDot: false
    showFiles: true
    showHidden: false
    showOnlyReadable: true
    sortField: FolderListModel.Name
    onStatusChanged: if (status === FolderListModel.Ready) {
      root.pickerIndex = count === 0 ? 0 : Math.min(root.pickerIndex, count - 1)
      if (panelFlick) panelFlick.contentY = 0
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.pickerOpen) {
          if (dx < 0) root.pickerGoParent()
          else if (dx > 0) root.pickerActivate()
          else root.pickerMove(dy)
        } else {
          root.moveCursor(dy)
        }
      }
      onActivateRequested: {
        if (root.pickerOpen) root.pickerActivate()
        else root.activateCursor()
      }
      onCloseRequested: {
        if (root.pickerOpen) root.closePicker()
        else root.close()
      }
      onTabRequested: function(direction) {
        if (!root.pickerOpen) root.switchPanel(direction)
      }
      onTextKey: function(t) {
        if (root.pickerOpen) {
          if (t === "h" || t === "H") root.pickerGoParent()
          else if (t === "q" || t === "Q") root.closePicker()
          return
        }
        if (t === "i" || t === "I") root.openPicker()
        else if (t === "r" || t === "R") tunnel.refresh()
        else if ((t === "d" || t === "D") && root.cursorIndex < root.profiles.length) {
          var profile = root.profiles[root.cursorIndex]
          if (profile) root.requestDelete(profile.uuid)
        }
      }

      Flickable {
        id: panelFlick
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
          width: panelFlick.width
          spacing: Style.space(12)

          Column {
            visible: !root.pickerOpen
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
                  textFormat: Text.PlainText
                  text: tunnel.activeCount > 0 ? "\uf023" : "\uf09c"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }

            Column {
              visible: details.active
              width: parent.width
              spacing: Style.space(4)

              InfoPair { label: "Profile"; value: details.profileName !== "" ? details.profileName : "—" }
              InfoPair { label: "Interface"; value: details.device !== "" ? details.device : "—" }
              InfoPair { label: "IP address"; value: details.ipAddress !== "" ? details.ipAddress : "—" }
              InfoPair { label: "Endpoint"; value: details.endpoint !== "" ? details.endpoint : "—" }
              InfoPair { label: "Traffic"; value: "↓ " + details.downloadedText + "   ↑ " + details.uploadedText }
              InfoPair { label: "Rate"; value: "↓ " + details.receivingText + "   ↑ " + details.sendingText }
            }

            Text {
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
              visible: tunnel.available
              width: parent.width
              text: "No elevated helper. Connections are managed by NetworkManager and authorized through its normal policy."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: root.pickerOpen
            width: parent.width
            spacing: Style.space(10)

            PanelHero {
              width: parent.width
              title: "Import WireGuard"
              meta: "Choose a .conf or .wg file"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: "\uf07c"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }

            CursorSurface {
              width: parent.width
              foreground: root.foreground
              fill: root.hoverFill
              implicitHeight: parentInner.implicitHeight + Style.space(10)

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.pickerGoParent()
              }

              RowLayout {
                id: parentInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: "\uf060"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "Parent folder"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.pickerPathText()
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }
              }
            }

            PanelSeparator {
              foreground: root.foreground
            }

            Text {
              textFormat: Text.PlainText
              visible: folderModel.status === FolderListModel.Loading
              width: parent.width
              text: "Loading folder…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              visible: folderModel.status === FolderListModel.Ready && folderModel.count === 0
              width: parent.width
              text: "No WireGuard .conf or .wg files in this folder."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Column {
              id: pickerColumn
              visible: folderModel.status === FolderListModel.Ready
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: folderModel

                PickerRow {
                  required property string fileName
                  required property url fileUrl
                  required property bool fileIsDir
                  required property int index
                  width: parent.width
                  entryName: root.boundedLocalText(fileName, 255)
                  entryUrl: fileUrl
                  directory: fileIsDir
                  rowIndex: index
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "←/H parent · ↑/↓ select · Enter/→ open · Esc/Q cancel"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  component ProfileRow: CursorSurface {
    id: row
    property var profile: null
    property int rowIndex: 0
    readonly property bool rowBusy: row.profile && tunnel.busyUuid === row.profile.uuid

    hasCursor: root.cursorActive && root.cursorIndex === row.rowIndex
    current: row.profile && row.profile.active === true
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: inner.implicitHeight + Style.space(12)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: row.profile && !row.rowBusy && !tunnel.importing
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.setCursor(row.rowIndex)
      onClicked: if (row.profile) tunnel.toggleProfile(row.profile.uuid)
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
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.profile ? row.profile.name : "WireGuard"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.profile && row.profile.active
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
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
      onClicked: root.openPicker()
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
        textFormat: Text.PlainText
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
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: "Import configuration"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
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
        onClicked: root.openPicker()
      }
    }
  }

  component PickerRow: CursorSurface {
    id: pickerRow
    property string entryName: ""
    property url entryUrl: ""
    property bool directory: false
    property int rowIndex: 0

    hasCursor: root.cursorActive && root.pickerOpen && root.pickerIndex === pickerRow.rowIndex
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: pickerInner.implicitHeight + Style.space(10)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.pickerIndex = pickerRow.rowIndex
      }
      onClicked: {
        root.pickerIndex = pickerRow.rowIndex
        root.pickerActivate()
      }
    }

    RowLayout {
      id: pickerInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: pickerRow.directory ? "\uf07b" : "\uf15b"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: pickerRow.entryName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: pickerRow.directory ? "Folder" : "WireGuard configuration"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: pickerRow.directory
        text: "\uf054"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
