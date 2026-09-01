function splitEscapedColon(line) {
  var parts = [];
  var current = "";
  var escaped = false;

  for (var i = 0; i < line.length; i++) {
    var ch = line.charAt(i);
    if (escaped) {
      current += ch;
      escaped = false;
    } else if (ch === "\\") {
      escaped = true;
    } else if (ch === ":") {
      parts.push(current);
      current = "";
    } else {
      current += ch;
    }
  }

  if (escaped) current += "\\";
  parts.push(current);
  return parts;
}

function isUuid(value) {
  return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(String(value || ""));
}

function parseProfiles(raw) {
  var rows = [];
  var lines = String(raw || "").split(/\r?\n/);

  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "") continue;
    var fields = splitEscapedColon(lines[i]);
    if (fields.length < 4) continue;

    var name = fields[0];
    var uuid = fields[1];
    var type = fields[2];
    var device = fields.slice(3).join(":");

    if (type !== "wireguard" || !isUuid(uuid)) continue;

    rows.push({
      name: name || "WireGuard",
      uuid: uuid,
      type: type,
      device: device,
      active: device !== "" && device !== "--"
    });
  }

  rows.sort(function(a, b) {
    if (a.active !== b.active) return a.active ? -1 : 1;
    var an = String(a.name || "").toLowerCase();
    var bn = String(b.name || "").toLowerCase();
    return an < bn ? -1 : (an > bn ? 1 : 0);
  });

  return rows;
}

function findNewProfile(beforeUuids, profiles) {
  var known = {};
  var before = beforeUuids || [];
  for (var i = 0; i < before.length; i++) known[String(before[i])] = true;

  var fresh = [];
  var rows = profiles || [];
  for (var j = 0; j < rows.length; j++) {
    if (!known[String(rows[j].uuid)]) fresh.push(rows[j]);
  }

  return fresh.length === 1 ? fresh[0] : null;
}

function cleanError(raw, fallback) {
  var text = String(raw || "").replace(/\x1b\[[0-9;]*m/g, "").trim();
  if (text === "") return fallback || "Operation failed";
  var lines = text.split(/\r?\n/);
  var last = lines[lines.length - 1].trim();
  if (last.length > 180) last = last.substring(0, 177) + "...";
  return last || fallback || "Operation failed";
}
