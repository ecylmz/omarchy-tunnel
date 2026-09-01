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

function boundedDisplayText(value, limit) {
  var maximum = Math.max(1, Math.min(Number(limit || 180), 512));
  var text = String(value || "").replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "").trim();
  if (text.length > maximum)
    text = maximum <= 3 ? text.substring(0, maximum) : text.substring(0, maximum - 3) + "...";
  return text;
}

function parseProfiles(raw) {
  var rows = [];
  var input = String(raw || "");
  if (input.length > 65536) {
    return { ok: false, profiles: [], error: "NetworkManager returned too much profile data" };
  }
  var lines = input.split(/\r?\n/);
  if (lines.length > 257) {
    return { ok: false, profiles: [], error: "NetworkManager returned too many profiles" };
  }

  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "") continue;
    if (lines[i].length > 768) continue;
    var fields = splitEscapedColon(lines[i]);
    if (fields.length < 4) continue;

    var name = fields[0];
    var uuid = fields[1];
    var type = fields[2];
    var device = fields.slice(3).join(":");

    if (type !== "wireguard" || !isUuid(uuid) || name.length > 128) continue;
    if (/[\x00-\x1f\x7f]/.test(name)) continue;
    if (device !== "" && device !== "--" && !/^[A-Za-z0-9_.:-]{1,15}$/.test(device)) continue;

    rows.push({
      name: name || "WireGuard",
      uuid: uuid.toLowerCase(),
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

  return { ok: true, profiles: rows, error: "" };
}

function parseImportResult(raw) {
  var text = String(raw || "");
  var match = text.match(/^OK:([0-9a-fA-F-]{36})\r?\n?$/);
  if (!match || !isUuid(match[1])) return "";
  return match[1].toLowerCase();
}

function cleanError(raw, fallback) {
  var text = String(raw || "");
  if (text.length > 8192) text = text.substring(text.length - 8192);
  text = text.replace(/\x1b\[[0-9;]*m/g, "").trim();
  if (text === "") return fallback || "Operation failed";
  var lines = text.split(/\r?\n/);
  var last = boundedDisplayText(lines[lines.length - 1], 180);
  return last || fallback || "Operation failed";
}
