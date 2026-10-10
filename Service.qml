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
  property bool importing: false
  property var splitTunnel: ({})
  property var splitQueue: []
  property string splitQueryUuid: ""

  readonly property string helperPath: localPath(Qt.resolvedUrl("scripts/omarchy-tunnel-helper.py"))
  readonly property int activeCount: {
    var count = 0
    for (var i = 0; i < profiles.length; i++) if (profiles[i].active) count += 1
    return count
  }
  readonly property bool busy: refreshing || actionProcess.running || importProcess.running

  function boundedCommand(command, timeoutMs, stdoutLimit, stderrLimit) {
    var wrapped = [
      "python3", helperPath, "run",
      "--timeout-ms", String(timeoutMs),
      "--stdout-limit", String(stdoutLimit),
      "--stderr-limit", String(stderrLimit),
      "--"
    ]
    for (var i = 0; i < command.length; i++) wrapped.push(command[i])
    return wrapped
  }

  function nmcli(args, timeoutMs, stdoutLimit, stderrLimit) {
    var command = ["nmcli", "--colors", "no"]
    for (var i = 0; i < args.length; i++) command.push(args[i])
    return boundedCommand(command, timeoutMs, stdoutLimit, stderrLimit)
  }

  function profileByUuid(uuid) {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].uuid === uuid) return profiles[i]
    }
    return null
  }

  function flash(message) {
    actionStatus = Model.boundedDisplayText(message, 180)
    statusTimer.restart()
  }

  function fail(message) {
    lastError = Model.boundedDisplayText(message || "Operation failed", 240)
    actionStatus = ""
  }

  function refresh() {
    if (refreshProcess.running) return
    refreshing = true
    refreshProcess.timedOut = false
    refreshProcess.awaitingExit = true
    refreshProcess.command = nmcli([
      "--terse", "--escape", "yes",
      "--fields", "NAME,UUID,TYPE,DEVICE",
      "connection", "show"
    ], 8000, 65536, 8192)
    refreshProcess.running = true
  }

  function toggleProfile(uuid) {
    var profile = profileByUuid(uuid)
    if (!profile || !Model.isUuid(uuid) || actionProcess.running || importing) return
    runProfileAction(profile.active ? "down" : "up", uuid)
  }

  function runProfileAction(kind, uuid) {
    if (!Model.isUuid(uuid) || actionProcess.running || importing) return
    actionKind = kind
    busyUuid = uuid
    lastError = ""
    actionStatus = kind === "up" ? "Connecting…" : kind === "down" ? "Disconnecting…" : "Removing…"

    var args
    if (kind === "up") {
      args = ["--wait", "20", "connection", "up", "uuid", uuid]
    } else if (kind === "down") {
      args = ["--wait", "20", "connection", "down", "uuid", uuid]
    } else if (kind === "delete") {
      args = ["--wait", "20", "connection", "delete", "uuid", uuid]
    } else {
      busyUuid = ""
      actionKind = ""
      return
    }
    actionProcess.timedOut = false
    actionProcess.awaitingExit = true
    actionProcess.command = nmcli(args, 24000, 4096, 4096)
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

  function isSplit(uuid) {
    return root.splitTunnel[uuid] === true
  }

  function pruneSplitStates() {
    var next = {}
    for (var i = 0; i < profiles.length; i++) {
      var uuid = profiles[i].uuid
      if (root.splitTunnel[uuid] === true || root.splitTunnel[uuid] === false) next[uuid] = root.splitTunnel[uuid]
    }
    var before = JSON.stringify(root.splitTunnel)
    root.splitTunnel = next
    if (JSON.stringify(next) !== before) root.splitTunnelChanged()
  }

  function refreshSplitStates() {
    pruneSplitStates()
    var queue = []
    for (var i = 0; i < profiles.length; i++) {
      var uuid = profiles[i].uuid
      if (!Model.isUuid(uuid)) continue
      if (root.splitTunnel[uuid] !== true && root.splitTunnel[uuid] !== false) queue.push(uuid)
    }
    root.splitQueue = queue
    pumpSplitQueue()
  }

  function querySplitState(uuid) {
    if (!Model.isUuid(uuid)) return
    if (root.splitQueryUuid !== "") return
    var args = Model.splitShowArgs(uuid)
    if (!args) return
    splitQueryProcess.timedOut = false
    splitQueryProcess.awaitingExit = true
    splitQueryProcess.requestUuid = uuid
    root.splitQueryUuid = uuid
    splitQueryProcess.command = nmcli(args, 5000, 64, 2048)
    splitQueryProcess.running = true
  }

  function pumpSplitQueue() {
    if (splitQueryProcess.running || root.splitQueryUuid !== "") return
    while (root.splitQueue.length > 0) {
      var uuid = root.splitQueue.shift()
      if (!Model.isUuid(uuid)) continue
      if (root.splitTunnel[uuid] === true || root.splitTunnel[uuid] === false) continue
      if (!profileByUuid(uuid)) continue
      querySplitState(uuid)
      return
    }
    root.splitQueue = []
  }

  function setSplitTunnel(uuid, enabled) {
    var profile = profileByUuid(uuid)
    if (!profile || !Model.isUuid(uuid) || actionProcess.running || importing) return
    var args = Model.splitModifyArgs(uuid, enabled === true)
    if (!args) {
      fail("Invalid split tunneling request")
      return
    }
    actionKind = enabled ? "split-on" : "split-off"
    busyUuid = uuid
    lastError = ""
    actionStatus = enabled ? "Enabling split tunneling…" : "Disabling split tunneling…"
    actionProcess.timedOut = false
    actionProcess.awaitingExit = true
    actionProcess.command = nmcli(args, 12000, 4096, 4096)
    actionProcess.running = true
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
    importing = true
    lastError = ""
    actionStatus = "Validating and securing import…"
    importProcess.timedOut = false
    importProcess.awaitingExit = true
    importProcess.command = ["python3", helperPath, "import", pendingImportPath]
    importProcess.running = true
  }

  function finishImportState() {
    importing = false
    pendingImportPath = ""
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

  Timer {
    interval: 12000
    repeat: false
    running: refreshProcess.running
    onTriggered: {
      refreshProcess.timedOut = true
      refreshProcess.awaitingExit = false
      refreshProcess.running = false
      root.refreshing = false
      root.probed = true
      root.available = false
      root.profiles = []
      root.fail("NetworkManager refresh timed out")
    }
  }

  Timer {
    interval: 28000
    repeat: false
    running: actionProcess.running
    onTriggered: {
      actionProcess.timedOut = true
      actionProcess.awaitingExit = false
      actionProcess.running = false
      root.busyUuid = ""
      root.actionKind = ""
      root.fail("NetworkManager operation timed out")
      delayedRefresh.restart()
    }
  }

  Timer {
    interval: 52000
    repeat: false
    running: importProcess.running
    onTriggered: {
      importProcess.timedOut = true
      importProcess.awaitingExit = false
      importProcess.running = false
      root.finishImportState()
      root.fail("WireGuard import timed out; recovery was requested")
      delayedRefresh.restart()
    }
  }

  Timer {
    interval: 8000
    repeat: false
    running: splitQueryProcess.running
    onTriggered: {
      splitQueryProcess.timedOut = true
      splitQueryProcess.awaitingExit = false
      splitQueryProcess.running = false
      root.splitQueryUuid = ""
      root.pumpSplitQueue()
    }
  }

  Process {
    id: refreshProcess
    property bool timedOut: false
    property bool awaitingExit: false
    running: false
    command: []
    // The helper enforces these byte ceilings before either collector sees data.
    stdout: StdioCollector { id: refreshStdout; waitForEnd: true }
    stderr: StdioCollector { id: refreshStderr; waitForEnd: true }
    onRunningChanged: if (!running && awaitingExit) Qt.callLater(function() {
      if (!refreshProcess.running && refreshProcess.awaitingExit) {
        refreshProcess.awaitingExit = false
        root.refreshing = false
        root.probed = true
        root.available = false
        root.profiles = []
        root.fail("NetworkManager refresh ended unexpectedly")
      }
    })
    onExited: function(exitCode) {
      awaitingExit = false
      if (timedOut) return
      root.refreshing = false
      root.probed = true
      if (exitCode !== 0) {
        root.available = false
        root.profiles = []
        root.lastError = Model.cleanError(refreshStderr.text, "NetworkManager is unavailable")
        return
      }
      var parsed = Model.parseProfiles(refreshStdout.text)
      if (!parsed.ok) {
        root.available = false
        root.profiles = []
        root.fail(parsed.error)
        return
      }
      root.available = true
      root.lastError = ""
      root.profiles = parsed.profiles
      root.refreshSplitStates()
    }
  }

  Process {
    id: actionProcess
    property bool timedOut: false
    property bool awaitingExit: false
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onRunningChanged: if (!running && awaitingExit) Qt.callLater(function() {
      if (!actionProcess.running && actionProcess.awaitingExit) {
        actionProcess.awaitingExit = false
        root.busyUuid = ""
        root.actionKind = ""
        root.fail("NetworkManager operation ended unexpectedly")
        delayedRefresh.restart()
      }
    })
    onExited: function(exitCode) {
      awaitingExit = false
      if (timedOut) return
      var kind = root.actionKind
      var uuid = root.busyUuid
      if (exitCode !== 0) {
        root.fail(Model.cleanError(actionStderr.text || actionStdout.text, "NetworkManager operation failed"))
      } else if (kind === "split-on" || kind === "split-off") {
        var enabled = kind === "split-on"
        var updated = {}
        for (var key in root.splitTunnel) updated[key] = root.splitTunnel[key]
        updated[uuid] = enabled
        root.splitTunnel = updated
        root.lastError = ""
        var profile = root.profileByUuid(uuid)
        if (profile && profile.active) root.flash(enabled ? "Split tunneling on — reconnect to apply" : "Full tunnel restored — reconnect to apply")
        else root.flash(enabled ? "Split tunneling enabled" : "Full tunnel restored")
      } else {
        root.lastError = ""
        root.flash(kind === "up" ? "Connected" : kind === "down" ? "Disconnected" : "Profile removed")
      }
      root.busyUuid = ""
      root.actionKind = ""
      delayedRefresh.restart()
    }
  }

  Process {
    id: importProcess
    property bool timedOut: false
    property bool awaitingExit: false
    running: false
    command: []
    // Import emits only "OK:<uuid>" or one <=512-byte sanitized error line.
    stdout: StdioCollector { id: importStdout; waitForEnd: true }
    stderr: StdioCollector { id: importStderr; waitForEnd: true }
    onRunningChanged: if (!running && awaitingExit) Qt.callLater(function() {
      if (!importProcess.running && importProcess.awaitingExit) {
        importProcess.awaitingExit = false
        root.finishImportState()
        root.fail("WireGuard import ended unexpectedly; recovery was requested")
        delayedRefresh.restart()
      }
    })
    onExited: function(exitCode) {
      awaitingExit = false
      if (timedOut) return
      root.finishImportState()
      var uuid = Model.parseImportResult(importStdout.text)
      if (exitCode !== 0 || !uuid) {
        root.fail(Model.cleanError(importStderr.text || importStdout.text, "WireGuard import failed safely"))
        delayedRefresh.restart()
        return
      }
      root.lastError = ""
      root.flash("WireGuard profile imported")
      delayedRefresh.restart()
    }
  }

  Process {
    id: splitQueryProcess
    property bool timedOut: false
    property bool awaitingExit: false
    property string requestUuid: ""
    running: false
    command: []
    stdout: StdioCollector { id: splitQueryStdout; waitForEnd: true }
    stderr: StdioCollector { id: splitQueryStderr; waitForEnd: true }
    onRunningChanged: if (!running && awaitingExit) Qt.callLater(function() {
      if (!splitQueryProcess.running && splitQueryProcess.awaitingExit) {
        splitQueryProcess.awaitingExit = false
        if (root.splitQueryUuid === splitQueryProcess.requestUuid) root.splitQueryUuid = ""
        root.pumpSplitQueue()
      }
    })
    onExited: function(exitCode) {
      awaitingExit = false
      var uuid = requestUuid
      if (root.splitQueryUuid === uuid) root.splitQueryUuid = ""
      if (!timedOut && exitCode === 0 && Model.isUuid(uuid)) {
        var parsed = Model.parseNeverDefault(splitQueryStdout.text)
        if (parsed.ok) {
          var updated = {}
          for (var key in root.splitTunnel) updated[key] = root.splitTunnel[key]
          updated[uuid] = parsed.split
          root.splitTunnel = updated
        }
      }
      root.pumpSplitQueue()
    }
  }
}
