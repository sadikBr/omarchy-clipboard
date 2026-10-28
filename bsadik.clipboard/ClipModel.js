// Pure helpers for the clipboard overlay. History entries come from the
// built-in omarchy.clipboard watcher ({type:"text",text} / {type:"image",path,mime}).
// Pins are our own copies of entries so they survive history rotation.

var previewLimit = 4096

// Nerd Font (Material Design) glyphs, built from code points so the source
// stays plain ASCII.
function glyph(cp) {
  cp -= 0x10000
  return String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF))
}

var icons = {
  text: glyph(0xF09A8),
  image: glyph(0xF02E9),
  link: glyph(0xF0339),
  file: glyph(0xF0214),
  color: glyph(0xF03D8),
  code: glyph(0xF0169),
  pin: glyph(0xF0403),
  pinOutline: glyph(0xF0931),
  search: glyph(0xF0349),
  clipboard: glyph(0xF014C),
  trash: glyph(0xF0A7A)
}

function normalize(value) {
  if (!value || typeof value !== "object") return null
  if (value.type === "text") {
    var text = String(value.text || "")
    return text.trim().length > 0 ? { type: "text", text: text } : null
  }
  if (value.type === "image" && value.path) {
    var entry = { type: "image", path: String(value.path), mime: String(value.mime || "image/png") }
    if (value.capturedAt) entry.capturedAt = String(value.capturedAt)
    return entry
  }
  return null
}

function keyOf(entry) {
  if (!entry) return ""
  return entry.type === "image" ? "image:" + entry.path : "text:" + entry.text
}

function parseList(raw) {
  try {
    var parsed = JSON.parse(String(raw || "[]"))
    if (!Array.isArray(parsed)) return []
    var out = []
    for (var i = 0; i < parsed.length; i++) {
      var e = normalize(parsed[i])
      if (e) out.push(e)
    }
    return out
  } catch (e) {
    return []
  }
}

function decodeFileUri(line) {
  var v = String(line || "").trim()
  if (v.indexOf("file://") !== 0) return ""
  var p = v.substring(7)
  if (p.indexOf("localhost/") === 0) p = p.substring(9)
  if (p.charAt(0) !== "/") return ""
  try { return decodeURIComponent(p) } catch (e) { return p }
}

function baseName(path) {
  var parts = String(path || "").split("/")
  return parts[parts.length - 1] || String(path || "")
}

function isImagePath(path) {
  return /\.(png|jpe?g|webp|gif|bmp|tiff?|svg)$/i.test(String(path || ""))
}

function plural(n, word) {
  return n + " " + word + (n === 1 ? "" : "s")
}

// Classify a text entry into a display kind with title/meta strings.
function describeText(text) {
  var head = text.length > previewLimit ? text.slice(0, previewLimit) : text
  var trimmed = head.trim()
  var lines = head.split(/\r?\n/)

  var paths = []
  for (var i = 0; i < lines.length; i++) {
    var p = decodeFileUri(lines[i])
    if (p) paths.push(p)
  }
  if (paths.length > 0) {
    return {
      kind: "file",
      title: paths.length === 1 ? baseName(paths[0]) : plural(paths.length, "file"),
      meta: paths.length === 1 ? paths[0] : paths.map(baseName).join(", "),
      body: paths.join("\n"),
      imagePath: paths.length === 1 && isImagePath(paths[0]) ? paths[0] : "",
      swatch: ""
    }
  }

  if (/^#(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(trimmed) || /^rgba?\([\d\s.,%]+\)$/i.test(trimmed)) {
    return { kind: "color", title: trimmed, meta: "Color", body: trimmed, imagePath: "", swatch: trimmed }
  }

  if (/^(https?|ftp):\/\/\S+$/i.test(trimmed)) {
    var host = trimmed.replace(/^[a-z]+:\/\//i, "").split(/[/?#]/)[0]
    return { kind: "link", title: trimmed, meta: "Link · " + host, body: trimmed, imagePath: "", swatch: "" }
  }

  var lineCount = text.split(/\r?\n/).length
  var looksLikeCode = lineCount > 1 && /[{};<>=]|^\s{2,}\S|=>|\bfunction\b|\bdef\b|\bimport\b/m.test(head)
  var meta = plural(text.length, "char")
  if (lineCount > 1) meta += " · " + plural(lineCount, "line")

  return {
    kind: looksLikeCode ? "code" : "text",
    title: trimmed.replace(/\s+/g, " "),
    meta: (looksLikeCode ? "Code · " : "") + meta,
    body: head,
    imagePath: "",
    swatch: ""
  }
}

function describe(entry) {
  if (entry.type === "image") {
    var ext = String(entry.mime || "image/png").replace("image/", "").toUpperCase()
    return {
      kind: "image",
      title: entry.capturedAt ? "Image from " + entry.capturedAt : "Image",
      meta: ext + " image",
      body: "",
      imagePath: entry.path,
      swatch: ""
    }
  }
  return describeText(entry.text)
}

function matchesTab(kind, pinned, tab) {
  if (tab === "pinned") return pinned
  if (tab === "images") return kind === "image" || kind === "file"
  if (tab === "text") return kind !== "image" && kind !== "file"
  return true
}

function matchesQuery(entry, info, needle) {
  if (!needle) return true
  var hay = entry.type === "image" ? info.title + " " + info.meta + " image screenshot" : (info.body + " " + info.meta)
  return hay.toLowerCase().indexOf(needle) !== -1
}

// Pinned entries first (in pin order), then history newest-first, skipping
// anything already shown as a pin.
function buildRows(history, pins, query, tab, limit) {
  var needle = String(query || "").trim().toLowerCase()
  var rows = []
  var pinnedKeys = {}
  var historyIndexByKey = {}

  for (var h = 0; h < history.length; h++) {
    var hk = keyOf(history[h])
    if (historyIndexByKey[hk] === undefined) historyIndexByKey[hk] = h
  }

  function push(entry, pinIndex, historyIndex) {
    var info = describe(entry)
    var pinned = pinIndex >= 0
    if (!matchesTab(info.kind, pinned, tab)) return
    if (!matchesQuery(entry, info, needle)) return
    rows.push({
      kind: info.kind,
      title: info.title.length > 300 ? info.title.slice(0, 300) : info.title,
      meta: info.meta,
      body: info.body,
      imagePath: info.imagePath,
      swatch: info.swatch,
      pinned: pinned,
      pinIndex: pinIndex,
      historyIndex: historyIndex,
      entryKey: keyOf(entry)
    })
  }

  for (var p = 0; p < pins.length && rows.length < limit; p++) {
    var pk = keyOf(pins[p])
    pinnedKeys[pk] = true
    push(pins[p], p, historyIndexByKey[pk] === undefined ? -1 : historyIndexByKey[pk])
  }

  for (var i = 0; i < history.length && rows.length < limit; i++) {
    if (pinnedKeys[keyOf(history[i])]) continue
    push(history[i], -1, i)
  }

  return rows
}
