import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var profile: null
  property bool pollingEnabled: false

  property string profileName: ""
  property string device: ""
  property string uuid: ""
  property string ipAddress: ""
  property string endpoint: ""
  property double rxBytes: 0
  property double txBytes: 0
  property double rxRate: 0
  property double txRate: 0

  property double _previousRx: -1
  property double _previousTx: -1
  property double _previousRxMs: 0
  property double _previousTxMs: 0

  readonly property string helperPath: localPath(Qt.resolvedUrl("scripts/omarchy-tunnel-helper.py"))
  readonly property bool active: root.pollingEnabled && root.uuid !== "" && root.device !== ""
  readonly property string downloadedText: formatBytes(root.rxBytes)
  readonly property string uploadedText: formatBytes(root.txBytes)
  readonly property string receivingText: formatRate(root.rxRate)
  readonly property string sendingText: formatRate(root.txRate)

  function isUuid(value) {
    return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(String(value || ""))
  }

  function isDevice(value) {
    // Linux interface names are at most 15 bytes. NetworkManager-generated
    // WireGuard names stay inside this conservative printable subset.
    return /^[A-Za-z0-9_.:-]{1,15}$/.test(String(value || ""))
  }

  function localPath(fileUrl) {
    var value = String(fileUrl || "")
    if (value.indexOf("file:///") !== 0) return ""
    try { return decodeURIComponent(value.substring(7)) } catch (e) { return "" }
  }

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

  function nmcli(args, stdoutLimit) {
    var command = ["nmcli", "--colors", "no"]
    for (var i = 0; i < args.length; i++) command.push(args[i])
    return boundedCommand(command, 5000, stdoutLimit, 2048)
  }

  function formatBytes(value) {
    var n = Number(value || 0)
    if (!isFinite(n) || n < 0) n = 0
    var units = ["B", "KB", "MB", "GB", "TB"]
    var index = 0
    while (n >= 1024 && index < units.length - 1) {
      n /= 1024
      index += 1
    }
    var digits = index === 0 ? 0 : (n >= 100 ? 0 : 1)
    return n.toFixed(digits) + " " + units[index]
  }

  function formatRate(value) {
    return formatBytes(value) + "/s"
  }

  function parseCounter(raw) {
    var text = String(raw || "")
    if (text.length > 32 || !/^[0-9]+\s*$/.test(text)) return -1
    var n = Number(text.trim())
    return isFinite(n) && n >= 0 ? n : -1
  }

  function parseAddress(raw) {
    var input = String(raw || "")
    if (input.length > 8192) return ""
    var lines = input.split(/\r?\n/)
    if (lines.length > 64) return ""
    for (var i = 0; i < lines.length; i++) {
      var value = lines[i].trim().replace(/\\:/g, ":")
      if (value === "" || value === "--") continue
      var slash = value.indexOf("/")
      var address = slash >= 0 ? value.substring(0, slash) : value
      if (address.length > 80 || !/^[A-Za-z0-9:.%_-]+$/.test(address)) return ""
      return address
    }
    return ""
  }

  function parseEndpoint(raw) {
    var text = String(raw || "")
    if (text.length > 8192) return ""
    var match = text.match(/(?:^|[,;\s])endpoint=([^,;\s]+)/)
    if (!match || !match[1]) return ""
    var endpoint = String(match[1]).replace(/\\:/g, ":")
    if (endpoint.length > 255 || /[\x00-\x20\x7f]/.test(endpoint)) return ""
    return endpoint
  }

  function clearTelemetry() {
    root.ipAddress = ""
    root.endpoint = ""
    root.rxBytes = 0
    root.txBytes = 0
    root.rxRate = 0
    root.txRate = 0
    root._previousRx = -1
    root._previousTx = -1
    root._previousRxMs = 0
    root._previousTxMs = 0
  }

  function reset() {
    root.profileName = ""
    root.device = ""
    root.uuid = ""
    clearTelemetry()
  }

  function syncProfile() {
    var next = root.profile
    if (!next || next.active !== true || !isUuid(next.uuid) || !isDevice(next.device)) {
      reset()
      return
    }

    var nextUuid = String(next.uuid)
    var nextDevice = String(next.device)
    var changed = root.uuid !== nextUuid || root.device !== nextDevice
    root.profileName = String(next.name || "WireGuard")
    root.uuid = nextUuid
    root.device = nextDevice

    if (changed) {
      clearTelemetry()
      scheduleRefresh()
    }
  }

  function scheduleRefresh() {
    // pollingEnabled, uuid and device are QML-bound values. Defer one event
    // turn so reopening the panel cannot observe the old active binding and
    // skip the first metadata refresh.
    Qt.callLater(function() {
      if (!root.pollingEnabled) return
      root.refreshMetadata()
      root.refreshTraffic()
    })
  }

  function refreshMetadata() {
    if (!root.active) return
    if (!addressProcess.running) {
      addressProcess.timedOut = false
      addressProcess.awaitingExit = true
      addressProcess.requestDevice = root.device
      addressProcess.command = nmcli(["--get-values", "IP4.ADDRESS,IP6.ADDRESS", "device", "show", root.device], 8192)
      addressProcess.running = true
    }
    if (!peerProcess.running) {
      peerProcess.timedOut = false
      peerProcess.awaitingExit = true
      peerProcess.requestUuid = root.uuid
      peerProcess.command = nmcli(["--get-values", "wireguard.peers", "connection", "show", "uuid", root.uuid], 8192)
      peerProcess.running = true
    }
  }

  function refreshTraffic() {
    if (!root.active) return
    if (!rxProcess.running) {
      rxProcess.timedOut = false
      rxProcess.awaitingExit = true
      rxProcess.requestDevice = root.device
      rxProcess.command = boundedCommand(["cat", "/sys/class/net/" + root.device + "/statistics/rx_bytes"], 2000, 64, 256)
      rxProcess.running = true
    }
    if (!txProcess.running) {
      txProcess.timedOut = false
      txProcess.awaitingExit = true
      txProcess.requestDevice = root.device
      txProcess.command = boundedCommand(["cat", "/sys/class/net/" + root.device + "/statistics/tx_bytes"], 2000, 64, 256)
      txProcess.running = true
    }
  }

  function applyRx(raw) {
    var value = parseCounter(raw)
    if (value < 0) return
    var now = Date.now()
    if (root._previousRx >= 0 && value >= root._previousRx && now > root._previousRxMs)
      root.rxRate = (value - root._previousRx) * 1000 / (now - root._previousRxMs)
    else
      root.rxRate = 0
    root.rxBytes = value
    root._previousRx = value
    root._previousRxMs = now
  }

  function applyTx(raw) {
    var value = parseCounter(raw)
    if (value < 0) return
    var now = Date.now()
    if (root._previousTx >= 0 && value >= root._previousTx && now > root._previousTxMs)
      root.txRate = (value - root._previousTx) * 1000 / (now - root._previousTxMs)
    else
      root.txRate = 0
    root.txBytes = value
    root._previousTx = value
    root._previousTxMs = now
  }

  onProfileChanged: syncProfile()
  onPollingEnabledChanged: {
    syncProfile()
    if (pollingEnabled) scheduleRefresh()
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.active
    onTriggered: root.refreshTraffic()
  }

  Timer {
    interval: 15000
    repeat: true
    running: root.active
    onTriggered: root.refreshMetadata()
  }

  Timer {
    interval: 8000
    running: addressProcess.running
    onTriggered: {
      addressProcess.timedOut = true
      addressProcess.awaitingExit = false
      addressProcess.running = false
      if (root.device === addressProcess.requestDevice) root.ipAddress = ""
    }
  }

  Timer {
    interval: 8000
    running: peerProcess.running
    onTriggered: {
      peerProcess.timedOut = true
      peerProcess.awaitingExit = false
      peerProcess.running = false
      if (root.uuid === peerProcess.requestUuid) root.endpoint = ""
    }
  }

  Timer {
    interval: 4000
    running: rxProcess.running
    onTriggered: {
      rxProcess.timedOut = true
      rxProcess.awaitingExit = false
      rxProcess.running = false
      if (root.device === rxProcess.requestDevice) root.rxRate = 0
    }
  }

  Timer {
    interval: 4000
    running: txProcess.running
    onTriggered: {
      txProcess.timedOut = true
      txProcess.awaitingExit = false
      txProcess.running = false
      if (root.device === txProcess.requestDevice) root.txRate = 0
    }
  }

  Process {
    id: addressProcess
    property bool timedOut: false
    property bool awaitingExit: false
    property string requestDevice: ""
    running: false
    command: []
    stdout: StdioCollector { id: addressStdout; waitForEnd: true }
    onRunningChanged: if (!running && awaitingExit) Qt.callLater(function() {
      if (!addressProcess.running && addressProcess.awaitingExit) {
        addressProcess.awaitingExit = false
        if (root.device === addressProcess.requestDevice) root.ipAddress = ""
      }
    })
    onExited: function(exitCode) {
      awaitingExit = false
      if (!timedOut && exitCode === 0 && root.active && root.device === requestDevice)
        root.ipAddress = root.parseAddress(addressStdout.text)
    }
  }

  Process {
    id: peerProcess
    property bool timedOut: false
    property bool awaitingExit: false
    property string requestUuid: ""
    running: false
    command: []
    stdout: StdioCollector { id: peerStdout; waitForEnd: true }
    onRunningChanged: if (!running && awaitingExit) Qt.callLater(function() {
      if (!peerProcess.running && peerProcess.awaitingExit) {
        peerProcess.awaitingExit = false
        if (root.uuid === peerProcess.requestUuid) root.endpoint = ""
      }
    })
    onExited: function(exitCode) {
      awaitingExit = false
      if (!timedOut && exitCode === 0 && root.active && root.uuid === requestUuid)
        root.endpoint = root.parseEndpoint(peerStdout.text)
    }
  }

  Process {
    id: rxProcess
    property bool timedOut: false
    property bool awaitingExit: false
    property string requestDevice: ""
    running: false
    command: []
    stdout: StdioCollector { id: rxStdout; waitForEnd: true }
    onRunningChanged: if (!running && awaitingExit) Qt.callLater(function() {
      if (!rxProcess.running && rxProcess.awaitingExit) {
        rxProcess.awaitingExit = false
        if (root.device === rxProcess.requestDevice) root.rxRate = 0
      }
    })
    onExited: function(exitCode) {
      awaitingExit = false
      if (!timedOut && exitCode === 0 && root.active && root.device === requestDevice)
        root.applyRx(rxStdout.text)
    }
  }

  Process {
    id: txProcess
    property bool timedOut: false
    property bool awaitingExit: false
    property string requestDevice: ""
    running: false
    command: []
    stdout: StdioCollector { id: txStdout; waitForEnd: true }
    onRunningChanged: if (!running && awaitingExit) Qt.callLater(function() {
      if (!txProcess.running && txProcess.awaitingExit) {
        txProcess.awaitingExit = false
        if (root.device === txProcess.requestDevice) root.txRate = 0
      }
    })
    onExited: function(exitCode) {
      awaitingExit = false
      if (!timedOut && exitCode === 0 && root.active && root.device === requestDevice)
        root.applyTx(txStdout.text)
    }
  }
}
