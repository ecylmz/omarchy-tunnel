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

  function nmcli(args) {
    var command = ["env", "LC_ALL=C", "nmcli", "--colors", "no"]
    for (var i = 0; i < args.length; i++) command.push(args[i])
    return command
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
    var n = Number(String(raw || "").trim())
    return isFinite(n) && n >= 0 ? n : -1
  }

  function parseAddress(raw) {
    var lines = String(raw || "").split(/\r?\n/)
    for (var i = 0; i < lines.length; i++) {
      var value = lines[i].trim().replace(/\\:/g, ":")
      if (value === "" || value === "--") continue
      var slash = value.indexOf("/")
      return slash >= 0 ? value.substring(0, slash) : value
    }
    return ""
  }

  function parseEndpoint(raw) {
    var text = String(raw || "")
    var match = text.match(/(?:^|[,;[:space:]])endpoint=([^,;[:space:]]+)/)
    if (!match || !match[1]) return ""
    return String(match[1]).replace(/\\:/g, ":").replace(/\\\\/g, "\\")
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
    if (!root.pollingEnabled || !next || next.active !== true ||
        !isUuid(next.uuid) || !isDevice(next.device)) {
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
      refreshMetadata()
      refreshTraffic()
    }
  }

  function refreshMetadata() {
    if (!root.active) return
    if (!addressProcess.running) {
      addressProcess.command = nmcli(["--get-values", "IP4.ADDRESS,IP6.ADDRESS", "device", "show", root.device])
      addressProcess.running = true
    }
    if (!peerProcess.running) {
      peerProcess.command = nmcli(["--get-values", "wireguard.peers", "connection", "show", "uuid", root.uuid])
      peerProcess.running = true
    }
  }

  function refreshTraffic() {
    if (!root.active) return
    if (!rxProcess.running) {
      rxProcess.command = ["cat", "/sys/class/net/" + root.device + "/statistics/rx_bytes"]
      rxProcess.running = true
    }
    if (!txProcess.running) {
      txProcess.command = ["cat", "/sys/class/net/" + root.device + "/statistics/tx_bytes"]
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
  onPollingEnabledChanged: syncProfile()

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

  Process {
    id: addressProcess
    running: false
    command: []
    stdout: StdioCollector { id: addressStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && root.active) root.ipAddress = root.parseAddress(addressStdout.text)
    }
  }

  Process {
    id: peerProcess
    running: false
    command: []
    stdout: StdioCollector { id: peerStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && root.active) root.endpoint = root.parseEndpoint(peerStdout.text)
    }
  }

  Process {
    id: rxProcess
    running: false
    command: []
    stdout: StdioCollector { id: rxStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && root.active) root.applyRx(rxStdout.text)
    }
  }

  Process {
    id: txProcess
    running: false
    command: []
    stdout: StdioCollector { id: txStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && root.active) root.applyTx(txStdout.text)
    }
  }
}
