// Pure rules for the Window Rules plugin: the rules.json v1 schema and its
// validation (the same codes, order and defaults as hypr/schema.lua), the
// compilation of a match (exact apps, exact or regex titles) to Hyprland's
// match properties, the RE2-compatibility check for match patterns, capture
// of an open window as a rule, bounded parsers for hyprctl output and the loader's describe(), and
// serialization that keeps fields this version does not know. QML binds to
// these functions so tests/model.test.js can exercise them in node.
.pragma library

var SCHEMA_VERSION = 1
var MAX_RULES = 200
var MAX_FILE_BYTES = 1048576
var MAX_DEPTH = 64
var MAX_NAME = 80
var MAX_PATTERN = 256
var MAX_MONITOR = 128
var MAX_ID = 48
// An apps-mode match lists at most this many exact window classes.
var MAX_CLASSES = 32
// Ranges of the numeric fields, which the editor's controls use too.
var MIN_WORKSPACE_ID = 1
var MAX_WORKSPACE_ID = 9999
var MIN_SLOT = 1
var MAX_SLOT = 10
var MIN_ARG = 1
var MAX_ARG = 99
var MIN_SIZE = 1
var MIN_POSITION = 0
var MAX_GEOMETRY = 16384
var MIN_OPACITY = 0.05
var MAX_OPACITY = 1
var SLOTS_PER_MONITOR = 10

// Limits for text that comes from other processes.
var MAX_CLIENTS = 512
var MAX_MONITORS = 16
var MAX_TEXT = 512
var MAX_DESCRIBE_ERRORS = 200
var MAX_RESOLVERS = 64
var MAX_CONFIG_ERRORS = 50
// A loader error's detail as a list row shows it.
var MAX_ERROR_DETAIL = 160
// A row's match label (the app list or the pattern) as the list shows it.
var MAX_MATCH_LABEL = 160
// The longest array-like list (a Qt list, or an object with a length) read
// as a list; anything longer, or with a length that is not a whole number,
// is not a list, so a forged length cannot make the panel walk it.
var MAX_LIST_LIKE = 4096

var ID_PATTERN = /^[a-z0-9][a-z0-9-]{0,47}$/
var SPECIAL_NAME = /^[A-Za-z0-9_-]{1,32}$/
var RESOLVER_NAME = /^[a-z0-9-]{1,32}$/
var CONTROL = /[\u0000-\u001f\u007f]/
var ADDRESS = /^0x[0-9a-f]{1,16}$/i
var DESC_PREFIX = "desc:"

// Every code validateDocument can return, in check order.
var FILE_CODES = ["invalid-file", "unsupported-version", "invalid-revision", "too-many-rules"]
var RULE_CODES = ["invalid-rule", "invalid-id", "duplicate-id", "invalid-name", "invalid-flag",
  "invalid-class", "invalid-title", "invalid-workspace", "invalid-layout", "invalid-size",
  "invalid-position", "invalid-monitor", "invalid-opacity", "conflicting-effects"]
// Codes only the loader reports through describe(), and parseDocument's own.
var LOADER_CODES = ["file-unreadable", "file-too-large", "invalid-json", "using-backup", "resolver-failed",
  "resolver-missing", "capability-missing", "handler-failed", "register-failed"]
// Codes only the editor's own checks return.
var EDITOR_CODES = ["pattern-syntax"]
var WARNING_CODES = ["warn-geometry-not-floating", "capture-position-clamped", "capture-workspace-unsupported",
  "warn-pattern-unchecked", "warn-pattern-negative"]

var WORKSPACE_TYPES = ["none", "id", "special", "monitor-slot", "resolver"]
var LAYOUTS = ["default", "tile", "float"]
var POSITION_TYPES = ["none", "center", "at"]
var FLAGS = ["fullscreen", "maximize", "pin", "noInitialFocus"]
// How a match identifies a window's class (README, "Schema v1"): "apps" lists exact
// classes, "regex" gives one RE2 pattern. A missing mode is "regex".
var MATCH_MODES = ["apps", "regex"]
var TITLE_MODES = ["exact", "regex"]

// Field order of a written rule; keys outside these lists are kept after them.
var RULE_KEYS = ["id", "name", "enabled", "match", "workspace", "follow", "layout", "size",
  "position", "monitor", "fullscreen", "maximize", "pin", "opacity", "noInitialFocus"]
var MATCH_KEYS = ["mode", "classes", "class", "title", "titleMode", "initial"]
var WORKSPACE_KEYS = { none: [], id: ["id"], special: ["name"], "monitor-slot": ["monitor", "slot"],
  resolver: ["resolver", "arg"] }
var WORKSPACE_ALL_KEYS = ["type", "id", "name", "monitor", "slot", "resolver", "arg"]
var POSITION_KEYS = { none: [], center: [], at: ["x", "y"] }
var POSITION_ALL_KEYS = ["type", "x", "y"]

var KNOWN_ERRORS = codeSet(FILE_CODES.concat(RULE_CODES, LOADER_CODES, EDITOR_CODES))
var KNOWN_WARNINGS = codeSet(WARNING_CODES)

// ---------- Helpers ----------

function codeSet(list) {
  var set = Object.create(null)
  for (var i = 0; i < list.length; i++) set[list[i]] = true
  return set
}

function isObject(value) { return value !== null && typeof value === "object" && !Array.isArray(value) }

function has(object, key) { return Object.prototype.hasOwnProperty.call(object, key) }

function isArrayLike(value) {
  return Array.isArray(value)
    || (value !== null && typeof value === "object" && Number.isSafeInteger(value.length)
      && value.length >= 0 && value.length <= MAX_LIST_LIKE)
}

// A plain array from an array or an array-like list of at most
// MAX_LIST_LIKE items, [] for anything else.
// Lists that reach Model.js from QML (Hyprland.monitors.values, a list held
// by a property or passed through a signal) are indexed like arrays but may
// not be Arrays, so every function QML calls reads its lists through this.
// The schema checks do not: in a rules file only an Array is a list.
function arrayLike(value) {
  if (Array.isArray(value)) return value
  if (!isArrayLike(value)) return []
  var out = []
  for (var i = 0; i < value.length; i++) out.push(value[i])
  return out
}

function contains(list, value) { return list.indexOf(value) >= 0 }

// JSON data only, so a plain copy is a full copy.
function clone(value) { return value === undefined ? undefined : JSON.parse(JSON.stringify(value)) }

function isInteger(value, min, max) {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= min && value <= max
}

function finiteNumber(value, fallback) {
  return typeof value === "number" && isFinite(value) ? value : fallback
}

// Length in Unicode code points, or -1 when the text holds a lone surrogate
// (the UTF-16 form of invalid UTF-8).
function codePointLength(text) {
  var count = 0
  for (var i = 0; i < text.length; i++) {
    var unit = text.charCodeAt(i)
    if (unit >= 0xd800 && unit <= 0xdbff) {
      var next = text.charCodeAt(i + 1)
      if (!(next >= 0xdc00 && next <= 0xdfff)) return -1
      i++
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return -1
    }
    count++
  }
  return count
}

function isText(value, min, max) {
  if (typeof value !== "string") return false
  var length = codePointLength(value)
  if (length < min || length > max) return false
  return !CONTROL.test(value)
}

// At most `limit` UTF-16 units, without splitting a surrogate pair.
function bounded(value, limit) {
  if (typeof value !== "string") return ""
  if (value.length <= limit) return value
  var cut = value.slice(0, limit)
  var last = cut.charCodeAt(cut.length - 1)
  return last >= 0xd800 && last <= 0xdbff ? cut.slice(0, -1) : cut
}

function utf8Length(text) {
  var bytes = 0
  for (var i = 0; i < text.length; i++) {
    var unit = text.charCodeAt(i)
    if (unit < 0x80) bytes += 1
    else if (unit < 0x800) bytes += 2
    else if (unit >= 0xd800 && unit <= 0xdbff) { bytes += 4; i++ }
    else bytes += 3
  }
  return bytes
}

function parseJson(text) {
  try { return { ok: true, value: JSON.parse(String(text)) } } catch (error) { return { ok: false } }
}

// The deepest nesting of arrays and objects in JSON text, outside strings.
function nestingDepth(text) {
  var depth = 0, deepest = 0, inString = false
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i)
    if (inString) {
      if (c === 0x5c) i++
      else if (c === 0x22) inString = false
    } else if (c === 0x22) {
      inString = true
    } else if (c === 0x5b || c === 0x7b) {
      if (++depth > deepest) deepest = depth
    } else if (c === 0x5d || c === 0x7d) {
      depth--
    }
  }
  return deepest
}

// Every number finite and every string and key free of lone surrogates,
// which the Lua decoder refuses and JSON.parse accepts.
function strictValue(value) {
  if (typeof value === "number") return isFinite(value)
  if (typeof value === "string") return codePointLength(value) >= 0
  if (Array.isArray(value)) {
    for (var i = 0; i < value.length; i++) if (!strictValue(value[i])) return false
    return true
  }
  if (isObject(value)) {
    for (var key in value)
      if (has(value, key) && (codePointLength(key) < 0 || !strictValue(value[key]))) return false
  }
  return true
}

// JSON as hypr/json.lua accepts it: no byte order mark, no lone surrogate,
// no number beyond a double, at most MAX_DEPTH levels and nothing after the
// value (JSON.parse already refuses empty text and trailing content).
function parseStrictJson(text) {
  var source = String(text)
  if (source.charCodeAt(0) === 0xfeff || codePointLength(source) < 0 || nestingDepth(source) > MAX_DEPTH) return { ok: false }
  var parsed = parseJson(source)
  return parsed.ok && strictValue(parsed.value) ? parsed : { ok: false }
}

// ---------- Patterns ----------

// Hyprland's prefix for a pattern that matches what does not match the rest.
var NEGATIVE_PREFIX = "negative:"
// RE2 flags written at the very start of a pattern, as in (?i)steam.
var LEADING_FLAGS = /^\(\?([imsU]+)\)/
var FLAG_CHAR = /^[imsU-]$/

// The forbidden-construct scan of README "Validation order", identical to hypr/schema.lua:
// lookaround, backreferences and JS-style named groups are refused outside
// character classes; RE2's own (?P<name>...) is allowed. Returns null on a
// forbidden construct, otherwise { source, flagGroup }: the pattern as JS
// source ((?P< written as (?< and a leading ] of a class escaped, so that
// RegExp reads it as RE2 does), and whether it holds an RE2 flag group such
// as (?i), (?-s) or (?U:...), which RegExp cannot read.
function scanPattern(pattern) {
  var out = ""
  var flagGroup = false
  var inClass = false
  var i = 0
  while (i < pattern.length) {
    var c = pattern.charAt(i)
    if (c === "\\") {
      var next = pattern.charAt(i + 1)
      if (!inClass && ((next >= "1" && next <= "9") || (next === "k" && pattern.charAt(i + 2) === "<"))) return null
      out += pattern.substr(i, 2)
      i += 2
      continue
    }
    if (inClass) {
      if (c === "]") inClass = false
      out += c
      i++
      continue
    }
    if (c === "[") {
      inClass = true
      out += "["
      i++
      if (pattern.charAt(i) === "^") { out += "^"; i++ }
      // Literal in RE2; JS would read [] as an empty class.
      if (pattern.charAt(i) === "]") { out += "\\]"; i++ }
      continue
    }
    if (c === "(" && pattern.charAt(i + 1) === "?") {
      var kind = pattern.charAt(i + 2)
      if (kind === "=" || kind === "!") return null
      if (kind === "<") {
        var after = pattern.charAt(i + 3)
        if (after === "=" || after === "!" || after === "_" || /^[A-Za-z]$/.test(after)) return null
      }
      if (kind === "P" && pattern.charAt(i + 3) === "<") {
        out += "(?<"
        i += 4
        continue
      }
      var end = i + 2
      while (FLAG_CHAR.test(pattern.charAt(end))) end++
      if (end > i + 2 && (pattern.charAt(end) === ")" || pattern.charAt(end) === ":")) flagGroup = true
    }
    out += c
    i++
  }
  return { source: out, flagGroup: flagGroup }
}

function patternCode(field) { return field === "title" ? "invalid-title" : "invalid-class" }

// What validateDocument checks, which hypr/schema.lua checks the same way:
// type, length, control characters and the forbidden-construct scan.
function patternShapeOk(pattern, field) {
  var min = field === "title" ? 0 : 1
  return isText(pattern, min, MAX_PATTERN) && scanPattern(pattern) !== null
}

function flagsSupported(flags) {
  try { new RegExp("", flags); return true } catch (error) { return false }
}

// Hyprland matches with RE2::FullMatch. With the m flag ^ and $ also match
// at line breaks, so the end of the text is asserted instead.
function fullMatch(source, flags) {
  if (flags.indexOf("m") < 0) return new RegExp("^(?:" + source + ")$", flags)
  var sticky = new RegExp("(?:" + source + ")(?![\\s\\S])", flags + "y")
  return { test: function(text) { sticky.lastIndex = 0; return sticky.test(text) } }
}

// The editor's view of a pattern: `error` is the field's schema code, or
// "pattern-syntax" when the schema accepts it and RegExp cannot compile it
// (Lua cannot tell a broken regex, and RE2 may accept what RegExp does not);
// `warning` is "warn-pattern-unchecked" when it uses RE2 flags RegExp cannot
// express (U, or a flag group anywhere but the start), or
// "warn-pattern-negative" for Hyprland's negative: prefix; `matcher` tests
// a full match of the pattern after the prefix, or is null when there is an
// error or the pattern cannot be checked here; `negative` tells the prefix.
function analyzePattern(pattern, field) {
  var result = { error: "", warning: "", negative: false, matcher: null }
  if (!patternShapeOk(pattern, field)) { result.error = patternCode(field); return result }
  result.negative = pattern.indexOf(NEGATIVE_PREFIX) === 0
  var body = result.negative ? pattern.slice(NEGATIVE_PREFIX.length) : pattern
  var lead = LEADING_FLAGS.exec(body)
  var flags = lead ? lead[1] : ""
  var scanned = scanPattern(lead ? body.slice(lead[0].length) : body)
  if (scanned === null) { result.error = patternCode(field); return result }
  var jsFlags = ["i", "m", "s"].filter(function(flag) { return flags.indexOf(flag) >= 0 }).join("")
  if (flags.indexOf("U") >= 0 || scanned.flagGroup || !flagsSupported(jsFlags)) {
    result.warning = "warn-pattern-unchecked"
    return result
  }
  try { result.matcher = fullMatch(scanned.source, jsFlags) } catch (error) { result.error = "pattern-syntax"; return result }
  if (result.negative) result.warning = "warn-pattern-negative"
  return result
}

// The editor's check: "" or the error code of analyzePattern.
function checkPattern(pattern, field) { return analyzePattern(pattern, field).error }

// Text as an RE2 literal, the same way hypr/schema.lua writes it: every
// ASCII character other than a letter, a digit or _ gets a backslash, and
// every other character is copied.
function escapeLiteral(text) { return String(text).replace(/[\u0000-\u002f\u003a-\u0040\u005b-\u005e\u0060\u007b-\u007f]/g, "\\$&") }

// The match's mode, with a missing one read as "regex" (README, "How a match compiles").
function matchMode(match) {
  return isObject(match) && match.mode !== undefined ? match.mode : "regex"
}

function titleModeOf(match) {
  return isObject(match) && match.titleMode !== undefined ? match.titleMode : "regex"
}

// The Hyprland match properties of a valid `match` (README, "How a match compiles"; the
// fixture's compileCases): apps become ^(c1|c2)$ of escaped classes, an exact
// title ^title$, a regex passes through; with `initial` the keys are
// initial_class and initial_title; an empty title adds no key.
function compileMatch(match) {
  var m = isObject(match) ? match : {}
  var initial = m.initial === true
  var out = {}
  out[initial ? "initial_class" : "class"] = matchMode(m) === "apps"
    ? "^(" + arrayLike(m.classes).map(escapeLiteral).join("|") + ")$"
    : m["class"]
  var title = typeof m.title === "string" ? m.title : ""
  if (title !== "")
    out[initial ? "initial_title" : "title"] = titleModeOf(m) === "exact" ? "^" + escapeLiteral(title) + "$" : title
  return out
}

// ---------- Validation ----------

function isMonitorDesc(value) {
  return isText(value, DESC_PREFIX.length + 1, MAX_MONITOR) && value.indexOf(DESC_PREFIX) === 0
}

function workspaceOk(w) {
  if (!isObject(w) || !contains(WORKSPACE_TYPES, w.type)) return false
  if (w.type === "id") return isInteger(w.id, MIN_WORKSPACE_ID, MAX_WORKSPACE_ID)
  if (w.type === "special") return typeof w.name === "string" && SPECIAL_NAME.test(w.name)
  if (w.type === "monitor-slot") return isMonitorDesc(w.monitor) && isInteger(w.slot, MIN_SLOT, MAX_SLOT)
  if (w.type === "resolver") return typeof w.resolver === "string" && RESOLVER_NAME.test(w.resolver) && isInteger(w.arg, MIN_ARG, MAX_ARG)
  return true
}

function sizeOk(size) {
  return size === null || (Array.isArray(size) && size.length === 2
    && isInteger(size[0], MIN_SIZE, MAX_GEOMETRY) && isInteger(size[1], MIN_SIZE, MAX_GEOMETRY))
}

function positionOk(p) {
  if (!isObject(p) || !contains(POSITION_TYPES, p.type)) return false
  return p.type !== "at" || (isInteger(p.x, MIN_POSITION, MAX_GEOMETRY) && isInteger(p.y, MIN_POSITION, MAX_GEOMETRY))
}

function opacityOk(value) {
  return value === null || (typeof value === "number" && isFinite(value) && value >= MIN_OPACITY && value <= MAX_OPACITY)
}

// Fills a missing field with its default; false when the present value fails `ok`.
function field(rule, key, fallback, ok) {
  if (rule[key] === undefined) {
    rule[key] = clone(fallback)
    return true
  }
  return ok(rule[key])
}

function isBool(value) { return typeof value === "boolean" }

// An apps-mode class list as the schema takes it: an Array of 1 to
// MAX_CLASSES strings, each 1 to MAX_PATTERN code points without control
// characters.
function classesOk(classes) {
  if (!Array.isArray(classes) || classes.length < 1 || classes.length > MAX_CLASSES) return false
  for (var i = 0; i < classes.length; i++) if (!isText(classes[i], 1, MAX_PATTERN)) return false
  return true
}

// The class part of a match (mode, classes or class) as README "Validation order" checks it.
function classPartOk(m) {
  var mode = matchMode(m)
  if (mode === "apps") return classesOk(m.classes)
  return mode === "regex" && patternShapeOk(m["class"], "class")
}

// The title part (title and titleMode); a missing title is "".
function titlePartOk(m) {
  var mode = titleModeOf(m)
  var title = m.title === undefined ? "" : m.title
  if (mode === "exact") return isText(title, 0, MAX_PATTERN)
  return mode === "regex" && patternShapeOk(title, "title")
}

// Fills the match defaults in place and keeps only the class key of its
// mode: `classes` in apps mode, `class` in regex mode.
function normalizeMatch(m) {
  if (m.mode === undefined) m.mode = "regex"
  if (m.mode === "apps") delete m["class"]
  else delete m.classes
  if (m.title === undefined) m.title = ""
  if (m.titleMode === undefined) m.titleMode = "regex"
  if (m.initial === undefined) m.initial = false
}

// The match check of README "Validation order", in its order: "" when it passes (and the
// match is then normalized), otherwise the rule's error code.
function matchError(rule) {
  if (!isObject(rule.match) || !classPartOk(rule.match)) return "invalid-class"
  if (!titlePartOk(rule.match)) return "invalid-title"
  if (rule.match.initial !== undefined && !isBool(rule.match.initial)) return "invalid-flag"
  normalizeMatch(rule.match)
  return ""
}

function ruleWarnings(rule) {
  var geometry = rule.size !== null || rule.position.type !== "none"
  return geometry && rule.layout !== "float" ? ["warn-geometry-not-floating"] : []
}

// One rule, first failure wins in the order of README "Validation order". `seen` holds the
// ids already taken; an id is taken as soon as it passes the id checks.
function validateRule(raw, seen) {
  var failed = function(code) { return { status: code, warnings: [], rule: null } }
  if (!isObject(raw)) return failed("invalid-rule")
  var rule = clone(raw)
  if (typeof rule.id !== "string" || !ID_PATTERN.test(rule.id)) return failed("invalid-id")
  if (seen[rule.id]) return failed("duplicate-id")
  seen[rule.id] = true
  if (!isText(rule.name, 1, MAX_NAME)) return failed("invalid-name")
  if (!field(rule, "enabled", true, isBool)) return failed("invalid-flag")
  var matchCode = matchError(rule)
  if (matchCode !== "") return failed(matchCode)
  if (!field(rule, "workspace", { type: "none" }, workspaceOk)) return failed("invalid-workspace")
  if (!field(rule, "follow", true, isBool)) return failed("invalid-flag")
  if (!field(rule, "layout", "default", function(v) { return contains(LAYOUTS, v) })) return failed("invalid-layout")
  if (!field(rule, "size", null, sizeOk)) return failed("invalid-size")
  if (!field(rule, "position", { type: "none" }, positionOk)) return failed("invalid-position")
  if (!field(rule, "monitor", null, function(v) { return v === null || isMonitorDesc(v) })) return failed("invalid-monitor")
  for (var i = 0; i < FLAGS.length; i++)
    if (!field(rule, FLAGS[i], false, isBool)) return failed("invalid-flag")
  if (!field(rule, "opacity", null, opacityOk)) return failed("invalid-opacity")
  if (rule.fullscreen && rule.maximize) return failed("conflicting-effects")
  return { status: "ok", warnings: ruleWarnings(rule), rule: rule }
}

function fileError(doc) {
  if (!isObject(doc) || typeof doc.version !== "number") return "invalid-file"
  if (Number.isInteger(doc.version) && doc.version > SCHEMA_VERSION) return "unsupported-version"
  if (doc.version !== SCHEMA_VERSION) return "invalid-file"
  if (doc.revision !== undefined && !isInteger(doc.revision, 0, Number.MAX_SAFE_INTEGER)) return "invalid-revision"
  if (!Array.isArray(doc.rules)) return "invalid-file"
  if (doc.rules.length > MAX_RULES) return "too-many-rules"
  return ""
}

function validateDocument(doc) {
  var code = fileError(doc)
  if (code !== "") return { file: code, rules: [] }
  var seen = Object.create(null)
  var rules = []
  for (var i = 0; i < doc.rules.length; i++) rules.push(validateRule(doc.rules[i], seen))
  return { file: "ok", rules: rules }
}

// ---------- File ----------

// `text` is the file's content, or null when there is no file. A zero-byte
// file is text like any other, and not JSON, as the loader sees it.
function parseDocument(text) {
  if (text === null || text === undefined)
    return { fileState: "missing", doc: null, validation: { file: "ok", rules: [] }, revision: 0, error: "" }
  var source = String(text)
  if (source.length > MAX_FILE_BYTES || utf8Length(source) > MAX_FILE_BYTES)
    return { fileState: "invalid", doc: null, validation: null, revision: 0, error: "file-too-large" }
  var parsed = parseStrictJson(source)
  if (!parsed.ok) return { fileState: "invalid", doc: null, validation: null, revision: 0, error: "invalid-json" }
  var validation = validateDocument(parsed.value)
  var state = validation.file === "ok" ? "ok" : validation.file === "unsupported-version" ? "unsupported" : "invalid"
  var revision = state === "ok" && parsed.value.revision !== undefined ? parsed.value.revision : 0
  return { fileState: state, doc: parsed.value, validation: validation, revision: revision,
    error: state === "ok" ? "" : validation.file }
}

// Known keys first in schema order (only those present, so a rule passed
// through unvalidated keeps what it has), then the rest in their own order.
function ordered(source, keys, allKnown) {
  var out = {}
  if (!isObject(source)) return clone(source)
  for (var i = 0; i < keys.length; i++)
    if (source[keys[i]] !== undefined) out[keys[i]] = clone(source[keys[i]])
  for (var key in source)
    if (has(source, key) && !contains(allKnown, key) && source[key] !== undefined) out[key] = clone(source[key])
  return out
}

// Keys of `extra` the rule lacks, so unknown fields of the rule as it was
// read survive an editor that built a fresh object.
function withMissing(target, extra) {
  if (!isObject(target) || !isObject(extra)) return target
  for (var key in extra)
    if (has(extra, key) && target[key] === undefined) target[key] = clone(extra[key])
  return target
}

function writtenRule(rule, original) {
  if (!isObject(rule)) return clone(rule)
  var source = withMissing(clone(rule), unknownOnly(original, RULE_KEYS))
  if (isObject(original) && isObject(original.match)) withMissing(source.match, unknownOnly(original.match, MATCH_KEYS))
  var out = ordered(source, RULE_KEYS, RULE_KEYS)
  if (isObject(out.match)) out.match = ordered(out.match, MATCH_KEYS, MATCH_KEYS)
  if (isObject(out.workspace))
    out.workspace = ordered(out.workspace, ["type"].concat(WORKSPACE_KEYS[out.workspace.type] || WORKSPACE_ALL_KEYS.slice(1)), WORKSPACE_ALL_KEYS)
  if (isObject(out.position))
    out.position = ordered(out.position, ["type"].concat(POSITION_KEYS[out.position.type] || POSITION_ALL_KEYS.slice(1)), POSITION_ALL_KEYS)
  return out
}

function unknownOnly(object, known) {
  var out = {}
  if (!isObject(object)) return out
  for (var key in object)
    if (has(object, key) && !contains(known, key)) out[key] = object[key]
  return out
}

// The file to write: `rules` in order, `revision` as given, and every
// top-level and per-rule field of `doc` this version does not know.
function serializeDocument(doc, rules, revision) {
  var out = { version: SCHEMA_VERSION, revision: revision, rules: [] }
  var originals = Object.create(null)
  if (isObject(doc)) {
    for (var key in doc)
      if (has(doc, key) && !contains(["version", "revision", "rules"], key)) out[key] = clone(doc[key])
    var known = arrayLike(doc.rules)
    for (var i = 0; i < known.length; i++) {
      var raw = known[i]
      if (isObject(raw) && typeof raw.id === "string" && !originals[raw.id]) originals[raw.id] = raw
    }
  }
  var list = arrayLike(rules)
  for (var j = 0; j < list.length; j++) {
    var rule = list[j]
    var original = isObject(rule) && typeof rule.id === "string" ? originals[rule.id] : undefined
    out.rules.push(writtenRule(rule, original))
  }
  return JSON.stringify(out, null, 2) + "\n"
}

// The i18n key of a save refused because the file changed since the draft began.
var CONFLICT_KEY = "state.conflict.title"

function refusal(reason, detail) {
  return { ok: false, reason: reason, detail: detail === undefined ? "" : String(detail) }
}

// What a save writes, decided before anything is touched. `base` is
// { revision, text } as captured when the draft began (`text` null when there
// was no file); `currentText` is the file as read just now (null when it is
// missing). A file whose text is no longer the base's is a conflict, whatever
// its revision says. The new document must pass the loader's file-level
// checks: at most MAX_RULES rules, a safe integer revision and at most
// MAX_FILE_BYTES of UTF-8. Rules that were already invalid are carried over
// as written. `doc`, when given, is the document whose unknown fields are
// kept; by default the current file's. `backup` tells whether the current
// file is a valid document worth keeping as rules.json.bak.
function savePlan(base, currentText, rules, doc) {
  var baseText = isObject(base) && typeof base.text === "string" ? base.text : null
  var current = typeof currentText === "string" ? currentText : null
  if (current !== baseText) return refusal(CONFLICT_KEY)
  var parsed = parseDocument(current)
  if (parsed.fileState !== "ok" && parsed.fileState !== "missing") return refusal(errorKey(parsed.error))
  var list = arrayLike(rules)
  if (list.length > MAX_RULES) return refusal("save.tooManyRules", MAX_RULES)
  var revision = parsed.revision + 1
  if (!isInteger(revision, 1, Number.MAX_SAFE_INTEGER)) return refusal(errorKey("invalid-revision"))
  var text = serializeDocument(doc === undefined ? parsed.doc : doc, list, revision)
  if (utf8Length(text) > MAX_FILE_BYTES) return refusal("save.tooLarge", utf8Length(text))
  var written = parseDocument(text)
  if (written.fileState !== "ok") return refusal(errorKey(written.error))
  return { ok: true, text: text, revision: revision, backup: parsed.fileState === "ok" }
}

// What Restore writes. `shown` is { known, text }: the file as the panel
// shows it (`known` false when it could not be read); `current` is
// { ok, text }: the fresh read (`ok` false when unreadable, `text` null when
// missing). A file that changed since it was shown is left alone; the backup
// must be a valid document.
function restorePlan(shown, current, backupText) {
  var s = isObject(shown) ? shown : { known: false, text: null }
  var c = isObject(current) ? current : { ok: false, text: null }
  var unchanged = s.known === true ? c.ok === true && c.text === s.text : c.ok !== true
  if (!unchanged) return refusal("restore.changed")
  var parsed = parseDocument(typeof backupText === "string" ? backupText : null)
  if (parsed.fileState !== "ok") return refusal("restore.none")
  return { ok: true, text: backupText, revision: parsed.revision }
}

// Seconds after which another writer's lock is taken to be abandoned.
var LOCK_STALE_SECONDS = 30

// After `mkdir rules.lock` failed: "remove" a lock older than
// LOCK_STALE_SECONDS and try again, "retry" when it is already gone (stat
// failed), or "busy". `statOut` is `stat -c %Y` output; one retry at most.
function lockStep(statCode, statOut, nowSeconds, retried) {
  if (retried === true) return "busy"
  if (statCode !== 0) return "retry"
  var text = String(statOut || "").trim()
  if (!/^\d{1,15}$/.test(text)) return "busy"
  return nowSeconds - Number(text) > LOCK_STALE_SECONDS ? "remove" : "busy"
}

// Why a save cannot start, as an i18n key, or "" when it can.
function saveBlocker(state) {
  var s = isObject(state) ? state : {}
  if (s.busy === true) return "save.busy"
  if (s.dirReady !== true) return "save.noStateDir"
  if (s.fileState !== "ok" && s.fileState !== "missing") return "save.notEditable"
  return ""
}

// Why a capture that arrives now is refused, as an i18n key, or "" when it
// may open in the editor: never under a view that hides the editor (the
// file is being read, is invalid or unsupported, or a conflict is open) nor
// while a save is in flight.
function captureBlocker(mode, busy) {
  if (busy === true) return "save.busy"
  if (mode === "loading") return "state.loading"
  if (mode === "conflict") return "capture.conflict"
  if (mode === "invalid" || mode === "unsupported") return "save.notEditable"
  return ""
}

// The panel's view, first match wins: loading until the file and the loader
// are known, then conflict, invalid, unsupported, editor, the setup
// instructions while the loader is missing and not dismissed, and the list.
function panelMode(state) {
  var s = isObject(state) ? state : {}
  if (s.ready !== true || s.loaderKnown !== true) return "loading"
  if (s.conflict === true) return "conflict"
  if (s.fileState === "invalid") return "invalid"
  if (s.fileState === "unsupported") return "unsupported"
  if (s.editorOpen === true) return "editor"
  if (s.loaderMissing === true && s.setupDismissed !== true) return "setup"
  return "list"
}

// ---------- New rules and capture ----------

// Ids as a list, or as the keys of a set.
function idList(existingIds) {
  if (isArrayLike(existingIds)) return arrayLike(existingIds)
  return isObject(existingIds) ? Object.keys(existingIds) : []
}

function trimDashes(text) { return text.replace(/^-+/, "").replace(/-+$/, "") }

function slugId(name, existingIds) {
  var taken = codeSet(idList(existingIds))
  var base = trimDashes(String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-"))
  base = trimDashes(base.slice(0, MAX_ID)) || "rule"
  if (!taken[base]) return base
  for (var n = 2; ; n++) {
    var suffix = "-" + n
    var candidate = trimDashes(base.slice(0, MAX_ID - suffix.length)) + suffix
    if (!taken[candidate]) return candidate
  }
}

// Display name from untrusted text: no control characters, at most 80 code points.
function cleanName(text) {
  var name = String(text || "").replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/ {2,}/g, " ").trim()
  var points = Array.from(name).filter(function(point) { return codePointLength(point) === 1 })
  return points.slice(0, MAX_NAME).join("").trim()
}

// The match a new rule starts with: apps mode, no app chosen yet (the editor
// asks for one before Save) and no title condition.
function defaultMatch() {
  return { mode: "apps", classes: [], title: "", titleMode: "exact", initial: false }
}

function defaultRule(id, name) {
  return { id: id, name: name, enabled: true, match: defaultMatch(), workspace: { type: "none" },
    follow: true, layout: "default", size: null, position: { type: "none" }, monitor: null,
    fullscreen: false, maximize: false, pin: false, opacity: null, noInitialFocus: false }
}

function newRule(name, existingIds) {
  var clean = cleanName(name)
  return defaultRule(slugId(clean, existingIds), clean)
}

function monitorById(monitors, id) {
  var list = arrayLike(monitors)
  for (var i = 0; i < list.length; i++)
    if (isObject(list[i]) && list[i].id === id) return list[i]
  return null
}

function clampGeometry(value, min) {
  return Math.min(MAX_GEOMETRY, Math.max(min, Math.round(finiteNumber(value, min))))
}

function capturedWorkspace(client, monitor, warnings) {
  var w = isObject(client.workspace) ? client.workspace : {}
  var id = finiteNumber(w.id, 0)
  var name = typeof w.name === "string" ? w.name : ""
  if (name.indexOf("special:") === 0 || id < 0) {
    var special = name.indexOf("special:") === 0 ? name.slice(8) : name
    if (SPECIAL_NAME.test(special)) return { type: "special", name: special }
    warnings.push("capture-workspace-unsupported")
    return { type: "none" }
  }
  if (!isInteger(id, 1, MAX_WORKSPACE_ID)) {
    warnings.push("capture-workspace-unsupported")
    return { type: "none" }
  }
  var desc = monitor && typeof monitor.description === "string" ? DESC_PREFIX + monitor.description : ""
  if (isMonitorDesc(desc)) return { type: "monitor-slot", monitor: desc, slot: ((id - 1) % SLOTS_PER_MONITOR) + 1 }
  return { type: "id", id: id }
}

function capturedPosition(client, monitor, warnings) {
  var at = arrayLike(client.at)
  if (!monitor || at.length !== 2) return { type: "none" }
  var x = Math.round(finiteNumber(at[0], 0) - finiteNumber(monitor.x, 0))
  var y = Math.round(finiteNumber(at[1], 0) - finiteNumber(monitor.y, 0))
  var cx = clampGeometry(x, 0), cy = clampGeometry(y, 0)
  if (cx !== x || cy !== y) warnings.push("capture-position-clamped")
  return { type: "at", x: cx, y: cy }
}

// An open window (one entry of `hyprctl clients -j` or `activewindow -j`, or
// parseClients' form of it) as a rule that puts the next such window where
// this one is: an apps-mode match on its exact class. `title` is the
// window's title, offered to the editor as an exact title with the filter off.
function ruleFromWindow(client, monitors, existingIds) {
  var warnings = []
  var c = isObject(client) ? client : {}
  var wmClass = typeof c["class"] === "string" ? c["class"] : ""
  var title = typeof c.title === "string" ? c.title : ""
  var rule = newRule(wmClass || title, existingIds)
  var monitor = monitorById(monitors, c.monitor)
  rule.match.classes = wmClass !== "" ? [wmClass] : []
  rule.workspace = capturedWorkspace(c, monitor, warnings)
  if (c.floating === true) {
    rule.layout = "float"
    var size = arrayLike(c.size)
    if (size.length === 2) rule.size = [clampGeometry(size[0], 1), clampGeometry(size[1], 1)]
    rule.position = capturedPosition(c, monitor, warnings)
  }
  // Hyprland's fullscreen state is a mask: 1 maximized, 2 fullscreen.
  var mode = c.fullscreen === true ? 2 : finiteNumber(c.fullscreen, 0)
  rule.fullscreen = (mode & 2) !== 0
  rule.maximize = !rule.fullscreen && (mode & 1) !== 0
  rule.pin = c.pinned === true
  return { rule: rule, warnings: warnings, title: title }
}

// ---------- hyprctl and loader output ----------

function pair(value) {
  if (!Array.isArray(value) || value.length !== 2) return null
  var a = finiteNumber(value[0], NaN), b = finiteNumber(value[1], NaN)
  return isNaN(a) || isNaN(b) ? null : [a, b]
}

// One client, bounded; null when it has no usable class.
function clientEntry(c) {
  if (!isObject(c) || typeof c["class"] !== "string" || c["class"] === "" || c["class"].length > MAX_TEXT) return null
  var w = isObject(c.workspace) ? c.workspace : {}
  var workspaceId = finiteNumber(w.id, 0)
  return {
    address: typeof c.address === "string" && ADDRESS.test(c.address) ? c.address : "",
    "class": c["class"],
    title: bounded(c.title, MAX_TEXT),
    initialClass: bounded(c.initialClass, MAX_TEXT),
    initialTitle: bounded(c.initialTitle, MAX_TEXT),
    floating: c.floating === true,
    size: pair(c.size),
    at: pair(c.at),
    monitor: Number.isSafeInteger(c.monitor) ? c.monitor : -1,
    workspace: { id: Number.isSafeInteger(workspaceId) ? workspaceId : 0, name: bounded(w.name, MAX_TEXT) },
    fullscreen: Number.isSafeInteger(c.fullscreen) && c.fullscreen >= 0 ? c.fullscreen : 0,
    pinned: c.pinned === true,
    pid: Number.isSafeInteger(c.pid) && c.pid > 0 ? c.pid : 0
  }
}

function jsonList(text, limit, parse) {
  var parsed = parseJson(text || "")
  if (!parsed.ok || !Array.isArray(parsed.value)) return []
  var out = []
  for (var i = 0; i < parsed.value.length && out.length < limit; i++) {
    var item = parse(parsed.value[i])
    if (item) out.push(item)
  }
  return out
}

function parseClients(text) { return jsonList(text, MAX_CLIENTS, clientEntry) }

// `hyprctl activewindow -j` prints {} when nothing has focus.
function parseActiveWindow(text) {
  var parsed = parseJson(text || "")
  return parsed.ok ? clientEntry(parsed.value) : null
}

function monitorEntry(m) {
  if (!isObject(m) || !Number.isSafeInteger(m.id) || typeof m.name !== "string" || m.name === "") return null
  var scale = finiteNumber(m.scale, 1)
  return { id: m.id, name: bounded(m.name, MAX_TEXT), description: bounded(m.description, MAX_TEXT),
    x: finiteNumber(m.x, 0), y: finiteNumber(m.y, 0), width: finiteNumber(m.width, 0),
    height: finiteNumber(m.height, 0), scale: scale > 0 ? scale : 1, focused: m.focused === true }
}

function parseMonitors(text) { return jsonList(text, MAX_MONITORS, monitorEntry) }

// The name of the display that has the keyboard focus (parseMonitors' list),
// where a capture belongs: the one marked focused, otherwise the focused
// window's (`client`, parseActiveWindow's form, may be null), otherwise "".
function focusedMonitorName(monitors, client) {
  var list = arrayLike(monitors)
  for (var i = 0; i < list.length; i++)
    if (isObject(list[i]) && list[i].focused === true && typeof list[i].name === "string") return list[i].name
  var own = isObject(client) ? monitorById(list, client.monitor) : null
  return own && typeof own.name === "string" ? own.name : ""
}

function count(value) { return Number.isSafeInteger(value) && value >= 0 ? value : 0 }

// The loader's describe() as printed by `hyprctl repl`. Anything that is not
// one JSON object with `loaded: true` (an `error: ...` line, no loader, a
// stray print) means the loader is not running. Each error keeps the rule's
// id and 1-based index in the file when it names one (null otherwise); the
// API version and the window counters since the last reload are whole
// numbers from 0, and 0 when missing or invalid.
function parseDescribe(text) {
  var parsed = parseJson(String(text || "").trim())
  if (!parsed.ok || !isObject(parsed.value) || parsed.value.loaded !== true) return { loaded: false }
  var d = parsed.value
  var resolvers = [], errors = []
  var rawResolvers = Array.isArray(d.resolvers) ? d.resolvers : []
  for (var i = 0; i < rawResolvers.length && resolvers.length < MAX_RESOLVERS; i++) {
    var r = rawResolvers[i]
    if (!isObject(r) || typeof r.name !== "string" || !RESOLVER_NAME.test(r.name)) continue
    resolvers.push({ name: r.name, label: bounded(r.label, MAX_TEXT), argLabel: bounded(r.argLabel, MAX_TEXT) })
  }
  var rawErrors = Array.isArray(d.errors) ? d.errors : []
  for (var j = 0; j < rawErrors.length && errors.length < MAX_DESCRIBE_ERRORS; j++) {
    var e = rawErrors[j]
    if (!isObject(e) || typeof e.code !== "string" || e.code === "") continue
    errors.push({ id: typeof e.id === "string" ? bounded(e.id, MAX_TEXT) : null,
      index: Number.isSafeInteger(e.index) && e.index >= 1 ? e.index : null,
      code: bounded(e.code, MAX_TEXT), detail: bounded(e.detail, MAX_TEXT) })
  }
  var counters = isObject(d.counters) ? d.counters : {}
  return { loaded: true, api: count(d.api), loaderVersion: bounded(d.loaderVersion, MAX_TEXT),
    schema: Number.isSafeInteger(d.schema) ? d.schema : 0,
    revision: Number.isSafeInteger(d.revision) && d.revision >= 0 ? d.revision : null,
    rules: count(d.rules), dynamic: count(d.dynamic),
    counters: { opened: count(counters.opened), matched: count(counters.matched), moved: count(counters.moved) },
    resolvers: resolvers, errors: errors }
}

// `hyprctl configerrors`: one error per line.
function parseConfigErrors(text) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length && out.length < MAX_CONFIG_ERRORS; i++) {
    var line = lines[i].trim()
    if (line !== "") out.push(bounded(line, MAX_TEXT))
  }
  return out
}

// ---------- Labels ----------

function fieldMatches(info, text) { return info.matcher.test(bounded(text, MAX_TEXT)) !== info.negative }

// One side (class or title) of a match as the preview tests it: `error`
// when the schema or RegExp refuses it, `unchecked` when the pattern cannot
// be checked here, and otherwise `test(text)`. `exact` lists the accepted
// texts of an apps list or an exact title; a regex goes through
// analyzePattern.
function previewSide(exact, pattern, field) {
  if (exact !== null) {
    var set = codeSet(exact)
    return { error: false, unchecked: false, test: function(text) { return set[text] === true } }
  }
  var info = analyzePattern(pattern, field)
  if (info.error !== "") return { error: true, unchecked: false, test: null }
  if (!info.matcher) return { error: false, unchecked: true, test: null }
  return { error: false, unchecked: false, test: function(text) { return fieldMatches(info, text) } }
}

function previewClassSide(m) {
  if (matchMode(m) === "apps") {
    var classes = arrayLike(m.classes)
    if (!classesOk(classes)) return { error: true, unchecked: false, test: null }
    return previewSide(classes, null, "class")
  }
  if (matchMode(m) !== "regex") return { error: true, unchecked: false, test: null }
  return previewSide(null, m["class"], "class")
}

// null when the match has no title condition.
function previewTitleSide(m) {
  var title = m.title === undefined ? "" : m.title
  if (title === "") return null
  if (titleModeOf(m) === "exact")
    return isText(title, 0, MAX_PATTERN) ? previewSide([title], null, "title") : { error: true, unchecked: false, test: null }
  if (titleModeOf(m) !== "regex") return { error: true, unchecked: false, test: null }
  return previewSide(null, title, "title")
}

// How many open windows the rule matches, by Hyprland's semantics: an app
// list by exact class, an exact title by equality, a regex by full match (a
// negative: pattern counts the windows the rest does not match); with
// `initial`, the class and title the window opened with. 0 for a match
// with an error, and null when a pattern cannot be checked here.
// Approximate: JS and RE2 differ in details such as Unicode classes. It runs
// on the UI thread, so at most MAX_CLIENTS windows and MAX_TEXT units of
// each class and title are tested.
function previewCount(rule, clients) {
  if (!isObject(rule) || !isObject(rule.match)) return 0
  var m = rule.match
  var classSide = previewClassSide(m)
  var titleSide = previewTitleSide(m)
  if (classSide.error || (titleSide && titleSide.error)) return 0
  if (classSide.unchecked || (titleSide && titleSide.unchecked)) return null
  var initial = m.initial === true
  var list = arrayLike(clients)
  var matched = 0
  for (var i = 0; i < list.length && i < MAX_CLIENTS; i++) {
    var c = list[i]
    if (!isObject(c)) continue
    var wmClass = initial ? c.initialClass : c["class"]
    if (typeof wmClass !== "string" || !classSide.test(wmClass)) continue
    var title = initial ? c.initialTitle : c.title
    if (titleSide && !titleSide.test(typeof title === "string" ? title : "")) continue
    matched++
  }
  return matched
}

function resolverLabel(name, resolvers) {
  var list = arrayLike(resolvers)
  for (var i = 0; i < list.length; i++)
    if (isObject(list[i]) && list[i].name === name && typeof list[i].label === "string" && list[i].label !== "") return list[i].label
  return name
}

// The i18n key and %1/%2 arguments that describe where the rule sends a
// window. `resolvers` (from parseDescribe) supplies resolver labels.
function targetSummary(rule, resolvers) {
  var w = isObject(rule) && isObject(rule.workspace) ? rule.workspace : { type: "none" }
  if (w.type === "id") return { key: "target.workspace", args: [String(w.id)] }
  if (w.type === "special") return { key: "target.special", args: [String(w.name)] }
  if (w.type === "monitor-slot") {
    var desc = String(w.monitor)
    return { key: "target.monitorSlot", args: [String(w.slot), desc.indexOf(DESC_PREFIX) === 0 ? desc.slice(DESC_PREFIX.length) : desc] }
  }
  if (w.type === "resolver") return { key: "target.resolver", args: [resolverLabel(w.resolver, resolvers), String(w.arg)] }
  return { key: "target.none", args: [] }
}

// The glyph a list row leads with, by target type: a special workspace, a
// numbered workspace, a display slot, a resolver, anywhere; an alert for a
// rule the schema refuses ("invalid").
var TARGET_GLYPHS = { special: 0xF0328, id: 0xF0570, "monitor-slot": 0xF0379, resolver: 0xF0871, none: 0xF05B2,
  invalid: 0xF0026 }

function targetGlyph(type) {
  return String.fromCodePoint(has(TARGET_GLYPHS, type) ? TARGET_GLYPHS[type] : TARGET_GLYPHS.none)
}

// Longest display description and resolver name a badge shows.
var BADGE_MONITOR = 12
var BADGE_RESOLVER = 24

// The i18n key and %1/%2 arguments of the compact badge a list row shows
// for where the rule sends a window ("ws 1", "scratchpad", "slot 3 · Example…",
// "external slot 3"); the long form is targetSummary.
function targetBadge(rule) {
  var w = isObject(rule) && isObject(rule.workspace) ? rule.workspace : { type: "none" }
  if (w.type === "id") return { key: "badge.workspace", args: [String(w.id)] }
  if (w.type === "special") return { key: "badge.special", args: [oneLine(w.name, BADGE_RESOLVER)] }
  if (w.type === "monitor-slot") {
    var desc = typeof w.monitor === "string" ? w.monitor : ""
    if (desc.indexOf(DESC_PREFIX) === 0) desc = desc.slice(DESC_PREFIX.length)
    return { key: "badge.monitorSlot", args: [String(w.slot), oneLine(desc, BADGE_MONITOR)] }
  }
  if (w.type === "resolver")
    return { key: "badge.resolver", args: [oneLine(String(w.resolver).replace(/-/g, " "), BADGE_RESOLVER), String(w.arg)] }
  return { key: "badge.none", args: [] }
}

// The summary strip over the list (listRows' rows, parseDescribe's loader):
// rules enabled and applicable, of all; enabled rules whose target depends on
// the displays (a display slot or a resolver); windows the loader moved since
// Hyprland last reloaded (null without a loader); and the problems the list
// marks: rows the schema refuses or the loader reported, the loader's errors
// that name no rule, and a file error.
function summaryCounts(rows, loader, fileError) {
  var list = arrayLike(rows)
  var loaded = isObject(loader) && loader.loaded === true
  var out = { total: list.length, enabled: 0, dynamic: 0, moved: null, errors: 0 }
  for (var i = 0; i < list.length; i++) {
    var row = list[i]
    if (!isObject(row)) continue
    var live = row.valid === true && row.enabled === true
    if (live) out.enabled++
    if (live && (row.target === "monitor-slot" || row.target === "resolver")) out.dynamic++
    if (row.valid !== true || row.loaderError === true) out.errors++
  }
  if (loaded) {
    out.moved = isObject(loader.counters) ? count(loader.counters.moved) : 0
    out.errors += globalErrors(loader.errors).length
  }
  if (typeof fileError === "string" && fileError !== "") out.errors++
  return out
}

// The state the panel's hero line names after the rule count, first match
// wins: { key, count }, key "" while the loader is not known yet.
function heroState(state) {
  var s = isObject(state) ? state : {}
  if (s.loaderKnown !== true) return { key: "", count: 0 }
  if (s.fileState === "invalid") return { key: "hero.invalid", count: 0 }
  if (s.fileState === "unsupported") return { key: "hero.unsupported", count: 0 }
  if (s.loaderLoaded !== true) return { key: "hero.noLoader", count: 0 }
  var errors = count(s.errors)
  if (errors > 0) return { key: "hero.errors", count: errors }
  return { key: "hero.ok", count: 0 }
}

// The capabilities without which the loader registers no rule at all, as
// hypr/window-rules.lua lists them; it names the missing one in the detail.
var STATIC_CAPABILITIES = ["o.window"]
var CAPABILITY_PREFIX = "missing capability: "

function staticCapabilityMissing(detail) {
  var text = typeof detail === "string" ? detail : ""
  if (text.indexOf(CAPABILITY_PREFIX) === 0) text = text.slice(CAPABILITY_PREFIX.length)
  for (var i = 0; i < STATIC_CAPABILITIES.length; i++) {
    var name = STATIC_CAPABILITIES[i]
    if (text === name || text.indexOf(name + ".") === 0) return true
  }
  return false
}

// Codes come from files and another process: never show one as text. A
// loader error's `detail` tells a capability-missing that stopped every
// rule from one that only turned the display-dependent targets off.
function errorKey(code, detail) {
  if (typeof code !== "string" || !KNOWN_ERRORS[code]) return "error.unknown"
  if (code === "capability-missing" && staticCapabilityMissing(detail)) return "error.capability-missing.static"
  return "error." + code
}

// errorKey for a code shown on the editor's match fields: an invalid-class
// of an apps-mode match has its own text, about the app list.
function matchErrorKey(code, match) {
  if (code === "invalid-class" && matchMode(match) === "apps") return "error.invalid-apps"
  return errorKey(code)
}

function warningKey(code) {
  return typeof code === "string" && KNOWN_WARNINGS[code] ? "warning." + code : "warning.unknown"
}

// ---------- Panel ----------

// The block of README "Add the loader block to Hyprland", added at the end of ~/.config/hypr/hyprland.lua.
// It survives a missing HOME, a relative XDG_CONFIG_HOME and a partial
// install: a loader that is absent, fails to load or returns no table.
var LOAD_BLOCK = [
  "do",
  "  local home = os.getenv(\"HOME\") or \"\"",
  "  local config = os.getenv(\"XDG_CONFIG_HOME\")",
  "  if not config or config:sub(1, 1) ~= \"/\" then config = home .. \"/.config\" end",
  "  local path = config .. \"/omarchy/plugins/io.github.ltecosta.window-rules/hypr/window-rules.lua\"",
  "  local file = io.open(path, \"r\")",
  "  if file then",
  "    file:close()",
  "    local ok, window_rules = pcall(dofile, path)",
  "    if ok and type(window_rules) == \"table\" then",
  "      -- window_rules.register_resolver(...)  -- optional, see \"Resolvers\"",
  "      window_rules.load()",
  "    end",
  "  end",
  "end"
].join("\n")

// Which editor field a validation code belongs to; "rule" for the rest.
var ERROR_FIELDS = { "invalid-id": "id", "duplicate-id": "id", "invalid-name": "name", "invalid-flag": "flags",
  "invalid-class": "class", "invalid-title": "title", "invalid-workspace": "workspace", "invalid-layout": "layout",
  "invalid-size": "size", "invalid-position": "position", "invalid-monitor": "monitor",
  "invalid-opacity": "opacity", "conflicting-effects": "flags" }

// ${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/<id>; a relative XDG value is ignored, as the spec says.
function stateDirectory(xdgStateHome, home, id) {
  var xdg = typeof xdgStateHome === "string" ? xdgStateHome : ""
  var base = xdg.charAt(0) === "/" ? xdg : String(home || "") + "/.local/state"
  return base.replace(/\/+$/, "") + "/omarchy/" + id
}

// The version a manifest.json declares, or "" when it has none.
function manifestVersion(text) {
  var parsed = parseJson(text || "")
  if (!parsed.ok || !isObject(parsed.value) || typeof parsed.value.version !== "string") return ""
  return /^\d+\.\d+\.\d+/.test(parsed.value.version) ? bounded(parsed.value.version, 32) : ""
}

// The rules the panel lists and edits, from parseDocument: each valid rule
// normalized, each invalid one as written so that a save keeps it.
function documentRules(parsed) {
  if (!isObject(parsed) || parsed.fileState !== "ok" || !isObject(parsed.validation)) return []
  var raw = isObject(parsed.doc) ? arrayLike(parsed.doc.rules) : []
  var entries = arrayLike(parsed.validation.rules)
  var out = []
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    out.push(entry.status === "ok" ? clone(entry.rule) : clone(raw[i]))
  }
  return out
}

function listOf(rules) { return arrayLike(rules) }

function validationOf(list) {
  var validation = validateDocument({ version: SCHEMA_VERSION, rules: list })
  var entries = []
  for (var i = 0; i < list.length; i++)
    entries.push(validation.file === "ok" ? validation.rules[i] : { status: validation.file, warnings: [], rule: null })
  return entries
}

// Untrusted text for display on one line, at most `limit` characters, an
// ellipsis marking a cut.
function oneLine(value, limit) {
  var text = String(typeof value === "string" ? value : "").replace(/[\u0000-\u001f\u007f]+/g, " ").trim()
  if (text.length <= limit) return text
  return bounded(text, limit - 1) + "\u2026"
}

// A loader error's detail for display.
function errorDetail(detail) { return oneLine(detail, MAX_ERROR_DETAIL) }

// The class part of a match as a list row shows it, on one line and at most
// MAX_MATCH_LABEL characters: the apps joined with ", " in apps mode, the
// pattern in regex mode. A rule as written may hold anything there, so only
// its strings are shown.
function matchLabel(match) {
  var m = isObject(match) ? match : {}
  var text = matchMode(m) === "apps"
    ? arrayLike(m.classes).filter(function(c) { return typeof c === "string" }).join(", ")
    : typeof m["class"] === "string" ? m["class"] : ""
  return oneLine(bounded(text, MAX_TEXT * 2), MAX_MATCH_LABEL)
}

function errorEntry(error) { return { key: errorKey(error.code, error.detail), detail: errorDetail(error.detail) } }

// The loader's errors (parseDescribe's form) that name no rule, neither by
// index nor by id, as { key, detail } for display.
function globalErrors(loaderErrors) {
  var errors = arrayLike(loaderErrors)
  var out = []
  for (var i = 0; i < errors.length; i++) {
    var e = errors[i]
    if (isObject(e) && typeof e.code === "string" && typeof e.id !== "string" && !Number.isSafeInteger(e.index)) out.push(errorEntry(e))
  }
  return out
}

// Which rows of `ids` a loader error belongs to: the row at its 1-based
// index, unless the error names an id that row no longer holds (the list
// was reordered since it was saved); otherwise every row with its id.
function errorRows(error, ids) {
  var at = Number.isSafeInteger(error.index) ? error.index - 1 : -1
  var named = typeof error.id === "string"
  if (at >= 0 && at < ids.length && (!named || ids[at] === error.id)) return [at]
  var rows = []
  if (named) for (var i = 0; i < ids.length; i++) if (ids[i] === error.id) rows.push(i)
  return rows
}

// What a list row shows, for every rule: plain fields bounded for display,
// the target type ("invalid" for a rule the schema refuses), summary and
// badge of a valid rule, its status, and the loader's
// describe() errors that belong to it as { key, detail }; a loader error
// that repeats the row's own validation status is left out.
function listRows(rules, resolvers, loaderErrors) {
  var list = listOf(rules)
  var entries = validationOf(list)
  var ids = list.map(function(raw) { return isObject(raw) && typeof raw.id === "string" ? raw.id : null })
  var rowErrors = list.map(function() { return [] })
  var errors = arrayLike(loaderErrors)
  for (var e = 0; e < errors.length; e++) {
    if (!isObject(errors[e]) || typeof errors[e].code !== "string") continue
    var at = errorRows(errors[e], ids)
    for (var r = 0; r < at.length; r++)
      if (errors[e].code !== entries[at[r]].status) rowErrors[at[r]].push(errorEntry(errors[e]))
  }
  var rows = []
  for (var i = 0; i < list.length; i++) {
    var entry = entries[i]
    var raw = isObject(list[i]) ? list[i] : {}
    var match = isObject(raw.match) ? raw.match : {}
    var id = typeof raw.id === "string" ? bounded(raw.id, MAX_TEXT) : ""
    var valid = entry.status === "ok"
    rows.push({
      index: i,
      id: id,
      name: cleanName(typeof raw.name === "string" && raw.name !== "" ? raw.name : id),
      matchMode: matchMode(match) === "apps" ? "apps" : "regex",
      matchLabel: matchLabel(match),
      summary: valid ? targetSummary(entry.rule, resolvers) : null,
      target: valid ? entry.rule.workspace.type : "invalid",
      badge: valid ? targetBadge(entry.rule) : null,
      enabled: valid ? entry.rule.enabled : raw.enabled !== false,
      valid: valid,
      errorKey: valid ? "" : errorKey(entry.status),
      warningKeys: entry.warnings.map(warningKey),
      errors: rowErrors[i],
      loaderError: rowErrors[i].length > 0
    })
  }
  return rows
}

// A catalog string with %1..%9 replaced in one pass, so an argument that
// itself holds "%2" (a window title, a loader version) stays as written.
// Placeholders without an argument are kept.
// args may be a Qt list (from a model or a signal), which is array-like but
// not an Array.
function fill(template, args) {
  var list = arrayLike(args)
  return String(template).replace(/%([1-9])/g, function(whole, n) {
    var value = list[Number(n) - 1]
    return value === undefined || value === null ? whole : String(value)
  })
}

// ---------- Panel: list edits (each returns a new list) ----------

function ruleIds(rules, skipIndex) {
  var list = listOf(rules)
  var ids = []
  for (var i = 0; i < list.length; i++)
    if (i !== skipIndex && isObject(list[i]) && typeof list[i].id === "string") ids.push(list[i].id)
  return ids
}

function moveRule(rules, index, delta) {
  var list = clone(listOf(rules))
  var target = index + delta
  if (index < 0 || index >= list.length || target < 0 || target >= list.length) return list
  var item = list.splice(index, 1)[0]
  list.splice(target, 0, item)
  return list
}

// Valid and invalid rules alike, as long as the entry is an object.
function setRuleEnabled(rules, index, enabled) {
  var list = clone(listOf(rules))
  if (index >= 0 && index < list.length && isObject(list[index])) list[index].enabled = enabled === true
  return list
}

// A copy right after the original, with the same name and a free id.
function duplicateRule(rules, index) {
  var list = clone(listOf(rules))
  if (index < 0 || index >= list.length || !isObject(list[index])) return list
  var copy = clone(list[index])
  copy.id = slugId(typeof copy.name === "string" && copy.name !== "" ? copy.name : copy.id, ruleIds(list, -1))
  list.splice(index + 1, 0, copy)
  return list
}

function removeRule(rules, index) {
  var list = clone(listOf(rules))
  if (index >= 0 && index < list.length) list.splice(index, 1)
  return list
}

// `rule` in place of the one at `index`, or appended when `index` is -1.
function putRule(rules, index, rule) {
  var list = clone(listOf(rules))
  var copy = clone(draftRule(rule))
  if (index >= 0 && index < list.length) list[index] = copy
  else list.push(copy)
  return list
}

function indexOfId(list, id) {
  for (var i = 0; i < list.length; i++) if (isObject(list[i]) && list[i].id === id) return i
  return -1
}

// After a conflict, the rule that was in the editor placed over the rules as
// reloaded: `original` is the rule it started as (null for a new rule).
// It goes back in place when the reloaded list still holds `original`
// unchanged, otherwise it is appended (index -1); either way it keeps its id
// unless another rule now holds it, and then takes a free one.
function reapplyRule(rules, original, rule) {
  var list = listOf(rules)
  var copy = clone(rule)
  if (!isObject(copy)) return { index: -1, rule: copy }
  var at = isObject(original) ? indexOfId(list, original.id) : -1
  if (at >= 0 && !sameJson(list[at], original)) at = -1
  var holder = indexOfId(list, copy.id)
  if (holder >= 0 && holder !== at)
    copy.id = slugId(typeof copy.name === "string" && copy.name !== "" ? copy.name : copy.id, ruleIds(list, at))
  return { index: at, rule: copy }
}

// What a confirmation about the entry at `index` remembers of it, so that
// the answer acts on that entry even if the list changed meanwhile: its
// index, id and canonical JSON (which tells apart invalid entries and
// entries that share an id), and the name the dialog shows. null when there
// is no entry there.
function entryIdentity(rules, index) {
  var list = listOf(rules)
  if (!Number.isSafeInteger(index) || index < 0 || index >= list.length) return null
  var entry = list[index]
  var id = isObject(entry) && typeof entry.id === "string" ? bounded(entry.id, MAX_TEXT) : ""
  var name = isObject(entry) && typeof entry.name === "string" && entry.name !== "" ? entry.name : id
  return { index: index, id: id, json: canonicalJson(entry), name: cleanName(name) }
}

// Where the entry `identity` (entryIdentity's result) is now in `rules`: its
// own index while the entry there is still the same, otherwise the index of
// an identical entry, the nearest to where it was, or -1 when it is gone.
function findEntry(rules, identity) {
  if (!isObject(identity) || typeof identity.json !== "string") return -1
  var list = listOf(rules)
  var at = identity.index
  if (Number.isSafeInteger(at) && at >= 0 && at < list.length && canonicalJson(list[at]) === identity.json) return at
  var best = -1
  for (var i = 0; i < list.length; i++) {
    if (canonicalJson(list[i]) !== identity.json) continue
    if (best < 0 || Math.abs(i - at) < Math.abs(best - at)) best = i
  }
  return best
}

// Reapplying the rule kept after a conflict (`kept` is { rule, original })
// over the reloaded `rules`: { ok, index, rule } as reapplyRule places it,
// or { ok: false, reason, detail } when it would be appended to a full file,
// in which case nothing should be cleared.
function reapplyPlan(rules, kept) {
  if (!isObject(kept)) return refusal("state.conflict.title")
  var placed = reapplyRule(rules, kept.original, kept.rule)
  if (placed.index < 0 && listOf(rules).length >= MAX_RULES) return refusal("save.tooManyRules", MAX_RULES)
  return { ok: true, index: placed.index, rule: placed.rule }
}

// JSON text with object keys sorted, so that key order (which a QML signal
// may change) does not count as a difference.
function canonicalJson(value) {
  if (Array.isArray(value)) return "[" + value.map(canonicalJson).join(",") + "]"
  if (isObject(value))
    return "{" + Object.keys(value).sort().map(function(key) { return JSON.stringify(key) + ":" + canonicalJson(value[key]) }).join(",") + "}"
  return value === undefined ? "null" : JSON.stringify(value)
}

function sameJson(a, b) { return canonicalJson(a) === canonicalJson(b) }

// ---------- Panel: editor ----------

// The usable classes of `list` (an Array or a Qt list) followed by `extra`,
// each once, in order: strings of 1 to MAX_PATTERN code points without
// control characters, at most MAX_CLASSES of them.
function uniqueClasses(list, extra) {
  var all = arrayLike(list).concat(arrayLike(extra))
  var out = [], seen = Object.create(null)
  for (var i = 0; i < all.length && out.length < MAX_CLASSES; i++) {
    var c = all[i]
    if (!isText(c, 1, MAX_PATTERN) || seen[c]) continue
    seen[c] = true
    out.push(c)
  }
  return out
}

// The editor's app choices: the distinct classes of the open windows
// (parseClients' form), each with the title of its first window as the
// description, followed by the rule's own classes that no window has.
function classOptions(clients, current) {
  var list = arrayLike(clients)
  var out = [], seen = Object.create(null)
  for (var i = 0; i < list.length && i < MAX_CLIENTS; i++) {
    var c = list[i]
    if (!isObject(c) || !isText(c["class"], 1, MAX_PATTERN) || seen[c["class"]]) continue
    seen[c["class"]] = true
    out.push({ value: c["class"], label: c["class"], description: oneLine(c.title, MAX_ERROR_DETAIL) })
  }
  var own = uniqueClasses(current)
  for (var j = 0; j < own.length; j++)
    if (!seen[own[j]]) { seen[own[j]] = true; out.push({ value: own[j], label: own[j], description: "" }) }
  return out
}

// The app list after adding the class `value` (typedClass' result):
// { classes, refused }, refused true and the list unchanged when it is
// already MAX_CLASSES long and `value` is not in it.
function addClass(classes, value) {
  var current = uniqueClasses(classes)
  if (value === "" || current.indexOf(value) >= 0) return { classes: current, refused: false }
  if (current.length >= MAX_CLASSES) return { classes: current, refused: true }
  return { classes: uniqueClasses(current, [value]), refused: false }
}

// A class typed into the editor, trimmed, or "" when it cannot be one.
function typedClass(text) {
  var value = String(typeof text === "string" ? text : "").trim()
  return isText(value, 1, MAX_PATTERN) ? value : ""
}

// The match after the editor switches its class mode. `stash` holds what
// the other mode had ({ classes, pattern }), so that switching back
// restores it; the result is { match, stash }. Going to regex without a
// stashed pattern starts from the pattern the apps compile to, so the rule
// keeps matching the same windows.
function switchMatchMode(match, mode, stash) {
  var m = clone(isObject(match) ? match : defaultMatch())
  var kept = isObject(stash) ? clone(stash) : {}
  var from = matchMode(m)
  if (from === mode || !contains(MATCH_MODES, mode)) return { match: m, stash: kept }
  if (from === "apps") kept.classes = uniqueClasses(m.classes)
  else if (typeof m["class"] === "string") kept.pattern = m["class"]
  if (mode === "regex") {
    var pattern = typeof kept.pattern === "string" ? kept.pattern : ""
    var classes = uniqueClasses(m.classes)
    if (pattern === "" && classes.length > 0) pattern = compileMatch({ mode: "apps", classes: classes })["class"]
    delete m.classes
    m["class"] = pattern
  } else {
    delete m["class"]
    m.classes = uniqueClasses(kept.classes)
  }
  m.mode = mode
  return { match: m, stash: kept }
}

// The title a title filter starts with when it is turned on in `toMode`:
// `title` as offered (a captured window's title, or the rule's own title as
// it opened) and the mode it was offered in. An exact title becomes the
// regex that matches exactly it; a regex cannot become an exact title.
function titleSuggestion(title, fromMode, toMode) {
  var text = typeof title === "string" ? title : ""
  if (text === "" || fromMode === toMode) return text
  return fromMode === "exact" && toMode === "regex" ? "^" + escapeLiteral(text) + "$" : ""
}

function shallowCopy(object) {
  var copy = {}
  for (var key in object) if (has(object, key)) copy[key] = object[key]
  return copy
}

// A rule from the editor with its size and its match's classes as Arrays: a
// rule that went through a QML property or signal may hold them as
// array-like lists.
function draftRule(rule) {
  if (!isObject(rule)) return rule
  var sizeList = !Array.isArray(rule.size) && isArrayLike(rule.size)
  var classList = isObject(rule.match) && !Array.isArray(rule.match.classes) && isArrayLike(rule.match.classes)
  if (!sizeList && !classList) return rule
  var copy = shallowCopy(rule)
  if (sizeList) copy.size = arrayLike(rule.size).slice()
  if (classList) {
    copy.match = shallowCopy(rule.match)
    copy.match.classes = arrayLike(rule.match.classes).slice()
  }
  return copy
}

function matchField(rule, key) {
  return isObject(rule) && isObject(rule.match) && typeof rule.match[key] === "string" ? rule.match[key] : ""
}

// The editor's check of the class side: the schema code for an app list,
// analyzePattern for a regex.
function classCheck(match) {
  var m = isObject(match) ? match : {}
  var mode = matchMode(m)
  if (mode === "apps") return { error: classesOk(m.classes) ? "" : "invalid-class", warning: "" }
  if (mode !== "regex") return { error: "invalid-class", warning: "" }
  return analyzePattern(m["class"], "class")
}

// The same for the title side; an empty title has nothing to check.
function titleCheck(match) {
  var m = isObject(match) ? match : {}
  var title = m.title === undefined ? "" : m.title
  var mode = titleModeOf(m)
  if (mode === "exact") return { error: isText(title, 0, MAX_PATTERN) ? "" : "invalid-title", warning: "" }
  if (mode !== "regex") return { error: "invalid-title", warning: "" }
  return title === "" ? { error: "", warning: "" } : analyzePattern(title, "title")
}

// A pattern error stops a save, except "pattern-syntax" on a pattern the
// draft did not change: RE2 may accept what RegExp cannot compile.
function patternBlocks(error, value, original, key) {
  if (error === "") return false
  return error !== "pattern-syntax" || !isObject(original) || matchField(original, key) !== value
}

// The editor's verdict on `draft` placed at `index` of `rules` (-1 appends):
// the first schema failure and the field it belongs to, the check of both
// sides of the match (an app list or exact title by the schema, a regex by
// analyzePattern), an id another rule already holds, and the warnings, those
// of the patterns included. `original`, when given, is the rule the draft
// started as.
function checkDraft(rules, index, draft, original) {
  var rule = draftRule(draft)
  var list = putRule(rules, index, rule)
  var at = index >= 0 && index < listOf(rules).length ? index : list.length - 1
  var entry = validationOf(list)[at]
  var status = entry.status
  if (status === "ok") {
    for (var i = 0; i < list.length; i++)
      if (i !== at && isObject(list[i]) && list[i].id === rule.id) { status = "duplicate-id"; break }
  }
  var match = isObject(rule) ? rule.match : undefined
  var className = matchField(rule, "class")
  var title = matchField(rule, "title")
  var classInfo = classCheck(match)
  var titleInfo = titleCheck(match)
  var warnings = status === "ok" ? entry.warnings.slice() : []
  for (var w = 0, notes = [classInfo.warning, titleInfo.warning]; w < notes.length; w++)
    if (notes[w] !== "" && warnings.indexOf(notes[w]) < 0) warnings.push(notes[w])
  return {
    ok: status === "ok" && !patternBlocks(classInfo.error, className, original, "class")
      && !patternBlocks(titleInfo.error, title, original, "title"),
    status: status,
    field: status === "ok" ? "" : (has(ERROR_FIELDS, status) ? ERROR_FIELDS[status] : "rule"),
    classError: classInfo.error,
    titleError: titleInfo.error,
    warnings: warnings
  }
}

// The match of repairRule: a valid mode is kept with an invalid class side
// emptied (an app list keeps its usable classes), an unknown mode starts
// over as an empty app list; an invalid title side becomes no title and an
// invalid `initial` false. `reset(code)` records each change.
function repairedMatch(match, reset) {
  var mode = matchMode(match)
  var out = defaultMatch()
  var classOk = classPartOk(match)
  if (!classOk) reset("invalid-class")
  if (mode === "regex") {
    delete out.classes
    out.mode = "regex"
    out["class"] = classOk ? match["class"] : ""
  } else if (mode === "apps") {
    out.classes = classOk ? clone(match.classes) : uniqueClasses(match.classes)
  }
  var titleMode = titleModeOf(match)
  if (contains(TITLE_MODES, titleMode)) out.titleMode = titleMode
  if (titlePartOk(match)) out.title = match.title === undefined ? "" : match.title
  else reset("invalid-title")
  if (match.initial !== undefined) {
    if (isBool(match.initial)) out.initial = match.initial
    else reset("invalid-flag")
  }
  return out
}

// A rule the schema refuses, made editable: `raw` as written with every
// missing field filled with its default, every valid field kept and every
// invalid one reset to its default. `fieldErrors` lists what was reset as
// { field, code }, field as ERROR_FIELDS names it. A missing, invalid or
// taken id (`existingIds` are the other rules') is replaced by a free one.
// Unknown fields are kept.
function repairRule(raw, existingIds) {
  var taken = codeSet(idList(existingIds))
  var source = isObject(raw) ? clone(draftRule(raw)) : {}
  var fieldErrors = []
  var reset = function(code) {
    var item = { field: has(ERROR_FIELDS, code) ? ERROR_FIELDS[code] : "rule", code: code }
    for (var i = 0; i < fieldErrors.length; i++)
      if (fieldErrors[i].field === item.field && fieldErrors[i].code === code) return
    fieldErrors.push(item)
  }
  if (!isObject(raw)) reset("invalid-rule")
  var name = isText(source.name, 1, MAX_NAME) ? source.name : ""
  var id = typeof source.id === "string" && ID_PATTERN.test(source.id) ? source.id : ""
  if (id === "") {
    if (isObject(raw)) reset("invalid-id")
    id = slugId(name || cleanName(source.name), taken)
  } else if (taken[id]) {
    reset("duplicate-id")
    id = slugId(id, taken)
  }
  if (name === "") {
    if (isObject(raw)) reset("invalid-name")
    name = cleanName(source.name) || id
  }
  var rule = defaultRule(id, name)
  var keep = function(key, ok, code) {
    if (source[key] === undefined) return
    if (ok(source[key])) rule[key] = clone(source[key])
    else reset(code)
  }
  keep("enabled", isBool, "invalid-flag")
  var match = isObject(source.match) ? source.match : {}
  rule.match = repairedMatch(match, reset)
  keep("workspace", workspaceOk, "invalid-workspace")
  keep("follow", isBool, "invalid-flag")
  keep("layout", function(v) { return contains(LAYOUTS, v) }, "invalid-layout")
  keep("size", sizeOk, "invalid-size")
  keep("position", positionOk, "invalid-position")
  keep("monitor", function(v) { return v === null || isMonitorDesc(v) }, "invalid-monitor")
  for (var f = 0; f < FLAGS.length; f++) keep(FLAGS[f], isBool, "invalid-flag")
  keep("opacity", opacityOk, "invalid-opacity")
  if (rule.fullscreen && rule.maximize) {
    rule.maximize = false
    reset("conflicting-effects")
  }
  withMissing(rule.match, unknownOnly(match, MATCH_KEYS))
  return { rule: withMissing(rule, unknownOnly(source, RULE_KEYS)), fieldErrors: fieldErrors }
}

// The workspace object for a newly chosen target type, keeping what still
// fits from `previous` and starting monitor-slot and resolver targets on the
// first display or resolver offered.
function workspaceFor(type, previous, monitor, resolver) {
  var p = isObject(previous) ? previous : {}
  if (type === "id") return { type: "id", id: isInteger(p.id, MIN_WORKSPACE_ID, MAX_WORKSPACE_ID) ? p.id : MIN_WORKSPACE_ID }
  if (type === "special")
    return { type: "special", name: typeof p.name === "string" && SPECIAL_NAME.test(p.name) ? p.name : "scratchpad" }
  if (type === "monitor-slot")
    return { type: "monitor-slot", monitor: isMonitorDesc(p.monitor) ? p.monitor : String(monitor || ""),
      slot: isInteger(p.slot, MIN_SLOT, MAX_SLOT) ? p.slot : MIN_SLOT }
  if (type === "resolver")
    return { type: "resolver", resolver: typeof p.resolver === "string" && RESOLVER_NAME.test(p.resolver) ? p.resolver : String(resolver || ""),
      arg: isInteger(p.arg, MIN_ARG, MAX_ARG) ? p.arg : MIN_ARG }
  return { type: "none" }
}

// Dropdown options for the displays, by description (Hyprland.monitors
// entries or parseMonitors' form), plus `current` when it is not connected.
function monitorOptions(monitors, current) {
  var list = arrayLike(monitors)
  var out = [], seen = Object.create(null)
  for (var i = 0; i < list.length && out.length < MAX_MONITORS; i++) {
    var m = list[i]
    var description = m && typeof m.description === "string" ? bounded(m.description, MAX_TEXT) : ""
    var value = DESC_PREFIX + description
    if (!isMonitorDesc(value) || seen[value]) continue
    seen[value] = true
    out.push({ value: value, label: description })
  }
  if (typeof current === "string" && current !== "" && !seen[current])
    out.push({ value: current, label: current.indexOf(DESC_PREFIX) === 0 ? current.slice(DESC_PREFIX.length) : current })
  return out
}

// Dropdown options for the resolvers describe() lists, plus `current` when
// it is not registered.
function resolverOptions(resolvers, current) {
  var list = arrayLike(resolvers)
  var out = [], seen = Object.create(null)
  for (var i = 0; i < list.length; i++) {
    var r = list[i]
    if (!isObject(r) || typeof r.name !== "string" || seen[r.name]) continue
    seen[r.name] = true
    out.push({ value: r.name, label: resolverLabel(r.name, list), argLabel: typeof r.argLabel === "string" ? r.argLabel : "" })
  }
  if (typeof current === "string" && current !== "" && !seen[current]) out.push({ value: current, label: current, argLabel: "" })
  return out
}

function resolverArgLabel(resolvers, name) {
  var options = resolverOptions(resolvers, "")
  for (var i = 0; i < options.length; i++) if (options[i].value === name) return options[i].argLabel
  return ""
}

// The highest describe() API version this panel knows.
var LOADER_API = 1

// What to tell the user about the loader, after a save or when its state is
// read: the i18n key and %1/%2 arguments of each note. `writtenRevision` is
// the revision written, or the file's when no save is in flight. A loader
// that reads an older rules format than SCHEMA_VERSION, or speaks a newer
// describe() API than LOADER_API, is named too.
function loaderNotes(loader, writtenRevision, pluginVersion) {
  if (!isObject(loader) || loader.loaded !== true) return []
  var notes = []
  if (loader.revision !== writtenRevision)
    notes.push({ key: "loader.revisionMismatch", args: [String(loader.revision), String(writtenRevision)] })
  if (typeof pluginVersion === "string" && pluginVersion !== "" && loader.loaderVersion !== pluginVersion)
    notes.push({ key: "loader.versionMismatch", args: [String(loader.loaderVersion), pluginVersion] })
  if (Number.isSafeInteger(loader.schema) && loader.schema < SCHEMA_VERSION)
    notes.push({ key: "loader.schemaOlder", args: [String(loader.schema), String(SCHEMA_VERSION)] })
  if (Number.isSafeInteger(loader.api) && loader.api > LOADER_API)
    notes.push({ key: "loader.apiNewer", args: [String(loader.api), String(LOADER_API)] })
  return notes
}
