import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property bool available: false
  property bool probed: false
  property bool refreshing: false
  property var profiles: []
  property string busyUuid: ""
  property string actionKind: ""
  property string actionStatus: ""
  property string lastError: ""
  property string pendingImportPath: ""
  property var preImportUuids: []
  property string importedUuid: ""
  property bool importing: false

  readonly property int activeCount: {
    var count = 0
    for (var i = 0; i < profiles.length; i++) if (profiles[i].active) count += 1
    return count
  }
  readonly property bool busy: refreshing || actionProcess.running || validatorProcess.running ||
    importProcess.running || discoverProcess.running || hardenProcess.running ||
    settleImportProcess.running || rollbackProcess.running

  readonly property string validatorProgram:
    'BEGIN { has_interface=0; has_peer=0; bad_hook=0 } ' +
    '{ line=tolower($0); ' +
    'if (line ~ /^[[:space:]]*\\[interface\\][[:space:]]*$/) has_interface=1; ' +
    'if (line ~ /^[[:space:]]*\\[peer\\][[:space:]]*$/) has_peer=1; ' +
    'if (line ~ /^[[:space:]]*(preup|postup|predown|postdown)[[:space:]]*=/) bad_hook=1 } ' +
    'END { if (bad_hook) exit 20; if (!has_interface) exit 21; if (!has_peer) exit 22; exit 0 }'

  function nmcli(args) {
    var command = ["env", "LC_ALL=C", "nmcli", "--colors", "no"]
    for (var i = 0; i < args.length; i++) command.push(args[i])
    return command
  }

  function profileByUuid(uuid) {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].uuid === uuid) return profiles[i]
    }
    return null
  }

  function flash(message) {
    actionStatus = String(message || "")
    statusTimer.restart()
  }

  function fail(message) {
    lastError = String(message || "Operation failed")
    actionStatus = ""
  }

  function refresh() {
    if (refreshProcess.running || discoverProcess.running) return
    refreshing = true
    refreshProcess.command = nmcli([
      "--terse", "--escape", "yes",
      "--fields", "NAME,UUID,TYPE,DEVICE",
      "connection", "show"
    ])
    refreshProcess.running = true
  }

  function toggleProfile(uuid) {
    var profile = profileByUuid(uuid)
    if (!profile || !Model.isUuid(uuid) || actionProcess.running || importing) return
    runProfileAction(profile.active ? "down" : "up", uuid)
  }

  function runProfileAction(kind, uuid) {
    if (!Model.isUuid(uuid) || actionProcess.running) return
    actionKind = kind
    busyUuid = uuid
    lastError = ""
    actionStatus = kind === "up" ? "Connecting…" : kind === "down" ? "Disconnecting…" : "Removing…"

    if (kind === "up") {
      actionProcess.command = nmcli(["--wait", "20", "connection", "up", "uuid", uuid])
    } else if (kind === "down") {
      actionProcess.command = nmcli(["--wait", "20", "connection", "down", "uuid", uuid])
    } else if (kind === "delete") {
      actionProcess.command = nmcli(["--wait", "20", "connection", "delete", "uuid", uuid])
    } else {
      busyUuid = ""
      actionKind = ""
      return
    }
    actionProcess.running = true
  }

  function removeProfile(uuid) {
    var profile = profileByUuid(uuid)
    if (!profile || !Model.isUuid(uuid)) return
    if (profile.active) {
      fail("Disconnect the tunnel before removing it")
      return
    }
    runProfileAction("delete", uuid)
  }

  function localPath(fileUrl) {
    var value = String(fileUrl || "")
    if (value.indexOf("file:///") !== 0) return ""
    try {
      return decodeURIComponent(value.substring(7))
    } catch (e) {
      return ""
    }
  }

  function importConfig(fileUrl) {
    if (busy) return
    var path = localPath(fileUrl)
    if (path === "") {
      fail("Only local WireGuard configuration files can be imported")
      return
    }
    pendingImportPath = path
    lastError = ""
    actionStatus = "Checking configuration…"
    validatorProcess.command = ["awk", validatorProgram, path]
    validatorProcess.running = true
  }

  function startImport() {
    preImportUuids = []
    for (var i = 0; i < profiles.length; i++) preImportUuids.push(profiles[i].uuid)
    importing = true
    actionStatus = "Importing WireGuard profile…"
    importProcess.command = nmcli([
      "--wait", "20", "connection", "import",
      "type", "wireguard", "file", pendingImportPath
    ])
    importProcess.running = true
  }

  function discoverImportedProfile() {
    discoverProcess.command = nmcli([
      "--terse", "--escape", "yes",
      "--fields", "NAME,UUID,TYPE,DEVICE",
      "connection", "show"
    ])
    discoverProcess.running = true
  }

  function hardenImportedProfile(uuid) {
    importedUuid = uuid
    var user = String(Quickshell.env("USER") || "")
    var args = ["--wait", "20", "connection", "modify", "uuid", uuid,
                "connection.autoconnect", "no"]
    if (user !== "") {
      args.push("connection.permissions")
      args.push("user:" + user)
    }
    actionStatus = "Securing imported profile…"
    hardenProcess.command = nmcli(args)
    hardenProcess.running = true
  }

  function rollbackImport(reason) {
    lastError = reason
    actionStatus = "Rolling back import…"
    if (!Model.isUuid(importedUuid)) {
      importing = false
      refresh()
      return
    }
    rollbackProcess.command = nmcli(["--wait", "20", "connection", "delete", "uuid", importedUuid])
    rollbackProcess.running = true
  }

  Timer {
    id: refreshTimer
    interval: 10000
    repeat: true
    triggeredOnStart: true
    running: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 500
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: statusTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: refreshProcess
    running: false
    command: []
    stdout: StdioCollector { id: refreshStdout; waitForEnd: true }
    stderr: StdioCollector { id: refreshStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      root.probed = true
      if (exitCode !== 0) {
        root.available = false
        root.profiles = []
        root.lastError = Model.cleanError(refreshStderr.text, "NetworkManager is unavailable")
        return
      }
      root.available = true
      root.lastError = ""
      root.profiles = Model.parseProfiles(refreshStdout.text)
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.fail(Model.cleanError(actionStderr.text || actionStdout.text, "NetworkManager operation failed"))
      } else {
        root.lastError = ""
        root.flash(root.actionKind === "up" ? "Connected" : root.actionKind === "down" ? "Disconnected" : "Profile removed")
      }
      root.busyUuid = ""
      root.actionKind = ""
      delayedRefresh.restart()
    }
  }

  Process {
    id: validatorProcess
    running: false
    command: []
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.startImport()
      } else if (exitCode === 20) {
        root.fail("Config rejected: PreUp/PostUp/PreDown/PostDown hooks are not allowed")
      } else if (exitCode === 21) {
        root.fail("Config rejected: missing [Interface] section")
      } else if (exitCode === 22) {
        root.fail("Config rejected: missing [Peer] section")
      } else {
        root.fail("Could not read the selected configuration")
      }
    }
  }

  Process {
    id: importProcess
    running: false
    command: []
    stdout: StdioCollector { id: importStdout; waitForEnd: true }
    stderr: StdioCollector { id: importStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.importing = false
        root.fail(Model.cleanError(importStderr.text || importStdout.text, "WireGuard import failed"))
        delayedRefresh.restart()
        return
      }
      root.discoverImportedProfile()
    }
  }

  Process {
    id: discoverProcess
    running: false
    command: []
    stdout: StdioCollector { id: discoverStdout; waitForEnd: true }
    stderr: StdioCollector { id: discoverStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.importing = false
        root.fail("Profile imported, but it could not be identified for hardening")
        delayedRefresh.restart()
        return
      }
      var rows = Model.parseProfiles(discoverStdout.text)
      var fresh = Model.findNewProfile(root.preImportUuids, rows)
      if (!fresh) {
        root.profiles = rows
        root.importing = false
        root.fail("Profile imported, but the new profile could not be identified safely")
        return
      }
      root.profiles = rows
      root.hardenImportedProfile(fresh.uuid)
    }
  }

  Process {
    id: hardenProcess
    running: false
    command: []
    stdout: StdioCollector { id: hardenStdout; waitForEnd: true }
    stderr: StdioCollector { id: hardenStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.rollbackImport("Import hardening failed; the new profile is being removed")
        return
      }
      root.actionStatus = "Finishing import…"
      settleImportProcess.command = root.nmcli(["--wait", "10", "connection", "down", "uuid", root.importedUuid])
      settleImportProcess.running = true
    }
  }

  Process {
    id: settleImportProcess
    running: false
    command: []
    stdout: StdioCollector { id: settleStdout; waitForEnd: true }
    stderr: StdioCollector { id: settleStderr; waitForEnd: true }
    onExited: function(exitCode) {
      // An inactive profile makes `nmcli connection down` return non-zero; that
      // is already the desired post-import state, so both outcomes are safe.
      root.importing = false
      root.pendingImportPath = ""
      root.preImportUuids = []
      root.importedUuid = ""
      root.lastError = ""
      root.flash("WireGuard profile imported")
      delayedRefresh.restart()
    }
  }

  Process {
    id: rollbackProcess
    running: false
    command: []
    stdout: StdioCollector { id: rollbackStdout; waitForEnd: true }
    stderr: StdioCollector { id: rollbackStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.importing = false
      root.pendingImportPath = ""
      root.preImportUuids = []
      if (exitCode === 0) {
        root.importedUuid = ""
        root.fail("Import was rolled back because the profile could not be hardened")
      } else {
        var uuid = root.importedUuid
        root.importedUuid = ""
        root.fail("Security hardening failed and rollback also failed. Remove profile " + uuid + " manually with nmcli.")
      }
      delayedRefresh.restart()
    }
  }
}
