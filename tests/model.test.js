// Tests for the Window Rules plugin's Model.js.
// Run from the plugin directory: node --test
"use strict"
const assert = require("node:assert")
const { test } = require("node:test")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const pluginDir = path.join(__dirname, "..")
const Model = {}
vm.runInNewContext(fs.readFileSync(path.join(pluginDir, "Model.js"), "utf8").replace(/^\.pragma library$/m, ""), Model)
// vm-context objects have a foreign prototype; compare them as plain JSON.
const plain = value => JSON.parse(JSON.stringify(value))
const catalog = JSON.parse(fs.readFileSync(path.join(pluginDir, "i18n", "en.json"), "utf8"))
const conformance = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "conformance.json"), "utf8"))

// A conformance document: the case's `document`, or `baseRule` with each
// override shallow-merged and its `$unset` keys removed.
function buildDocument(entry) {
  if (entry.document !== undefined) return entry.document
  const rules = entry.rules.map(over => {
    const rule = { ...structuredClone(conformance.baseRule), ...over }
    delete rule.$unset
    for (const key of over.$unset || []) delete rule[key]
    return rule
  })
  return { version: 1, revision: 0, rules }
}

const doc = rules => ({ version: 1, revision: 3, rules })
const base = (over = {}) => ({ ...structuredClone(conformance.baseRule), ...over })
const validate = rules => plain(Model.validateDocument(doc(rules)))
const status = over => validate([base(over)]).rules[0].status

const MONITORS = [
  { id: 0, name: "eDP-1", description: "Example Panel A1", x: 0, y: 0, width: 2560, height: 1600, scale: 1.6 },
  { id: 1, name: "DP-2", description: "Example Display B2", x: 1600, y: -200, width: 3440, height: 1440, scale: 1 }
]
const win = (over = {}) => ({ address: "0xabc", class: "org.example.Editor", title: "notes.txt - Editor",
  floating: false, size: [1200, 800], at: [1700, -150], monitor: 1, workspace: { id: 13, name: "13" },
  fullscreen: 0, pinned: false, pid: 4242, ...over })

const tests = {}

for (const entry of conformance.cases) {
  tests["conformance: " + entry.description] = () => {
    const result = plain(Model.validateDocument(buildDocument(entry)))
    assert.strictEqual(result.file, entry.expect.file)
    assert.deepStrictEqual(result.rules.map(r => r.status), entry.expect.rules)
    if (entry.expect.warnings) assert.deepStrictEqual(result.rules.map(r => r.warnings), entry.expect.warnings)
    for (const r of result.rules) assert.strictEqual(r.rule === null, r.status !== "ok")
  }
}

// Raw file text, through each implementation's own JSON parser.
for (const entry of conformance.textCases) {
  tests["conformance text: " + entry.description] = () => {
    const parsed = plain(Model.parseDocument(entry.text))
    assert.strictEqual(parsed.error || "ok", entry.expect.file)
    assert.deepStrictEqual(parsed.validation ? parsed.validation.rules.map(r => r.status) : [], entry.expect.rules)
  }
}

// The Hyprland match properties both implementations compile a match to.
for (const entry of conformance.compileCases) {
  tests["conformance compile: " + entry.description] = () => {
    assert.strictEqual(plain(Model.validateDocument(doc([base({ match: entry.match })]))).rules[0].status, "ok")
    assert.deepStrictEqual(plain(Model.compileMatch(entry.match)), entry.expect)
  }
}

Object.assign(tests, {
  "conformance: 201 rules is too many, 200 is not"() {
    const many = n => Array.from({ length: n }, (_, i) => base({ id: "r" + i }))
    assert.deepStrictEqual(plain(Model.validateDocument(doc(many(201)))), { file: "too-many-rules", rules: [] })
    const ok = plain(Model.validateDocument(doc(many(200))))
    assert.strictEqual(ok.file, "ok")
    assert.strictEqual(ok.rules.filter(r => r.status === "ok").length, 200)
  },

  "normalization fills every default and keeps unknown fields"() {
    const result = validate([{ id: "a", name: "A", match: { "class": "^a$", future: 1 }, extra: { deep: [1] } }]).rules[0]
    assert.strictEqual(result.status, "ok")
    assert.deepStrictEqual(result.warnings, [])
    assert.deepStrictEqual(result.rule, { id: "a", name: "A", match: { mode: "regex", "class": "^a$", title: "", titleMode: "regex", initial: false, future: 1 }, extra: { deep: [1] },
      enabled: true, workspace: { type: "none" }, follow: true, layout: "default", size: null, position: { type: "none" },
      monitor: null, fullscreen: false, maximize: false, pin: false, noInitialFocus: false, opacity: null })
  },

  "normalization does not change the input document"() {
    const input = doc([{ id: "a", name: "A", match: { "class": "^a$" } }])
    const before = JSON.stringify(input)
    Model.validateDocument(input)
    assert.strictEqual(JSON.stringify(input), before)
  },

  "null is a value, not a missing field"() {
    assert.strictEqual(status({ enabled: null }), "invalid-flag")
    assert.strictEqual(status({ workspace: null }), "invalid-workspace")
    assert.strictEqual(status({ match: { "class": "^a$", title: null } }), "invalid-title")
    assert.strictEqual(status({ size: null, monitor: null, opacity: null }), "ok")
    assert.strictEqual(plain(Model.validateDocument({ version: 1, revision: null, rules: [] })).file, "invalid-revision")
  },

  "a duplicate id is reported even when the first holder fails later"() {
    assert.deepStrictEqual(validate([base({ id: "x", name: "" }), base({ id: "x" })]).rules.map(r => r.status),
      ["invalid-name", "duplicate-id"])
  },

  "limits are counted in code points"() {
    assert.strictEqual(status({ name: "😀".repeat(80) }), "ok")
    assert.strictEqual(status({ name: "😀".repeat(81) }), "invalid-name")
    assert.strictEqual(status({ match: { "class": "a".repeat(256) } }), "ok")
    assert.strictEqual(status({ match: { "class": "a".repeat(257) } }), "invalid-class")
    assert.strictEqual(status({ match: { "class": "^a$", title: "é".repeat(256) } }), "ok")
    assert.strictEqual(status({ match: { "class": "^a$", title: "é".repeat(257) } }), "invalid-title")
    assert.strictEqual(status({ monitor: "desc:" + "x".repeat(123) }), "ok")
    assert.strictEqual(status({ monitor: "desc:" + "x".repeat(124) }), "invalid-monitor")
    assert.strictEqual(status({ monitor: "desc:" }), "invalid-monitor")
    assert.strictEqual(status({ workspace: { type: "id", id: 9999 } }), "ok")
    assert.strictEqual(status({ workspace: { type: "special", name: "a".repeat(33) } }), "invalid-workspace")
    assert.strictEqual(status({ workspace: { type: "monitor-slot", monitor: "desc:X", slot: 10 } }), "ok")
    assert.strictEqual(status({ workspace: { type: "monitor-slot", monitor: "desc:X", slot: 0 } }), "invalid-workspace")
    assert.strictEqual(status({ workspace: { type: "resolver", resolver: "a".repeat(33), arg: 1 } }), "invalid-workspace")
    assert.strictEqual(status({ layout: "float", size: [16384, 1] }), "ok")
    assert.strictEqual(status({ layout: "float", size: [16385, 1] }), "invalid-size")
    assert.strictEqual(status({ layout: "float", size: [1, 2, 3] }), "invalid-size")
    assert.strictEqual(status({ layout: "float", position: { type: "at", x: 16384, y: 0 } }), "ok")
    assert.strictEqual(status({ layout: "float", position: { type: "at", x: 0 } }), "invalid-position")
    assert.strictEqual(status({ opacity: 0.05 }), "ok")
    assert.strictEqual(status({ opacity: 1 }), "ok")
    assert.strictEqual(status({ opacity: "0.5" }), "invalid-opacity")
  },

  "control characters and invalid text fail the field"() {
    assert.strictEqual(status({ name: "a\u007fb" }), "invalid-name")
    assert.strictEqual(status({ name: "a\nb" }), "invalid-name")
    assert.strictEqual(status({ name: "a\ud800b" }), "invalid-name")
    assert.strictEqual(status({ match: { "class": "^a\tb$" } }), "invalid-class")
    assert.strictEqual(status({ match: { "class": "^a$", title: "x\u0000" } }), "invalid-title")
    assert.strictEqual(status({ match: { "class": "\udc00" } }), "invalid-class")
    assert.strictEqual(Model.checkPattern("a\u001fb", "class"), "invalid-class")
    assert.strictEqual(status({ monitor: "desc:A\u0001B" }), "invalid-monitor")
    assert.strictEqual(status({ workspace: { type: "monitor-slot", monitor: "desc:A\nB", slot: 1 } }), "invalid-workspace")
  },

  "markup-shaped text is kept as data"() {
    const name = "<b>Bold</b> &amp; <img src=x onerror=alert(1)>"
    const result = validate([base({ name, match: { "class": "^<i>$", title: "&lt;" } })]).rules[0]
    assert.strictEqual(result.status, "ok")
    assert.strictEqual(result.rule.name, name)
    assert.strictEqual(result.rule.match.title, "&lt;")
    const captured = plain(Model.ruleFromWindow(win({ class: "<b>x</b>", title: "<script>" }), MONITORS, []))
    assert.strictEqual(captured.rule.name, "<b>x</b>")
    assert.deepStrictEqual(captured.rule.match.classes, ["<b>x</b>"])
    assert.strictEqual(captured.title, "<script>")
    assert.strictEqual(Model.matchLabel(captured.rule.match), "<b>x</b>")
  },

  "forbidden constructs are found only outside character classes"() {
    const bad = ["(?=a)", "(?!a)", "(?<=a)b", "(?<!a)b", "(a)\\1", "(a)\\9", "(?<a>x)\\k<a>", "(?<name>x)", "(?<_x>y)"]
    for (const p of bad) assert.strictEqual(Model.checkPattern(p, "class"), "invalid-class", p)
    for (const p of bad) assert.strictEqual(status({ match: { "class": p } }), "invalid-class", p)
    const good = ["a\\\\1", "[(?=]a", "[\\1]", "[](?=]x", "[^](?!]x", "\\(?=a\\)", "(?P<name>steam)", "(?:a|b)", "\\0", "a{2}"]
    for (const p of good) assert.strictEqual(status({ match: { "class": p } }), "ok", p)
    for (const p of good) assert.strictEqual(Model.checkPattern(p, "class"), "", p)
    assert.strictEqual(Model.checkPattern("(?!x)", "title"), "invalid-title")
    assert.strictEqual(Model.checkPattern("", "title"), "")
    assert.strictEqual(Model.checkPattern("", "class"), "invalid-class")
    assert.strictEqual(Model.checkPattern(7, "class"), "invalid-class")
  },

  "syntax errors are caught by checkPattern only, like the Lua side"() {
    for (const p of ["(", "a[", "*a", "a{2,1}", "negative:("]) {
      assert.strictEqual(Model.checkPattern(p, "class"), "pattern-syntax", p)
      assert.strictEqual(status({ match: { "class": p } }), "ok", p)
    }
    assert.strictEqual(Model.checkPattern("(", "title"), "pattern-syntax")
    // Its own text: the pattern may still be valid RE2.
    assert.notStrictEqual(catalog["error.pattern-syntax"], catalog["error.invalid-class"])
    assert.match(catalog["error.pattern-syntax"], /may still accept/)
    assert.match(catalog["error.invalid-class"], /RE2 does not support/)
  },

  "parseDocument reports the file state"() {
    assert.deepStrictEqual(plain(Model.parseDocument(null)).fileState, "missing")
    assert.deepStrictEqual(plain(Model.parseDocument(undefined)).fileState, "missing")
    // A zero-byte file exists: it is invalid JSON, as the loader reads it, so Restore is offered.
    const empty = plain(Model.parseDocument(""))
    assert.deepStrictEqual([empty.fileState, empty.error], ["invalid", "invalid-json"])
    const broken = plain(Model.parseDocument("{"))
    assert.deepStrictEqual([broken.fileState, broken.error], ["invalid", "invalid-json"])
    const future = plain(Model.parseDocument('{"version": 2, "rules": []}'))
    assert.deepStrictEqual([future.fileState, future.error], ["unsupported", "unsupported-version"])
    const bad = plain(Model.parseDocument('{"version": 1, "revision": -2, "rules": []}'))
    assert.deepStrictEqual([bad.fileState, bad.error], ["invalid", "invalid-revision"])
    const ok = plain(Model.parseDocument(JSON.stringify(doc([base(), base({ id: "x", layout: "x" })]))))
    assert.deepStrictEqual([ok.fileState, ok.error, ok.revision], ["ok", "", 3])
    assert.deepStrictEqual(ok.validation.rules.map(r => r.status), ["ok", "invalid-layout"])
    assert.strictEqual(Model.parseDocument('{"version": 1, "rules": []}').revision, 0)
    const huge = plain(Model.parseDocument(JSON.stringify({ version: 1, rules: [], pad: "é".repeat(600000) })))
    assert.deepStrictEqual([huge.fileState, huge.error], ["invalid", "file-too-large"])
    assert.strictEqual(Model.parseDocument("﻿{\"version\":1,\"rules\":[]}").fileState, "invalid")
  },

  "serializeDocument keeps unknown fields and writes the given order"() {
    const original = { version: 1, revision: 4, comment: "kept", rules: [
      base({ id: "a", future: { x: 1 }, match: { "class": "^a$", title: "", xwayland: true } }),
      base({ id: "b", note: "b note" })] }
    const parsed = Model.parseDocument(JSON.stringify(original))
    const rules = parsed.validation.rules.map(r => r.rule)
    // The editor rebuilt "b" from its form fields, without the unknown one.
    const edited = base({ id: "b", name: "B2", layout: "float", size: [800, 600] })
    const text = Model.serializeDocument(parsed.doc, [edited, rules[0]], 5)
    assert.ok(text.endsWith("}\n"))
    assert.ok(text.includes('\n  "version": 1,\n'))
    const written = JSON.parse(text)
    assert.deepStrictEqual(Object.keys(written), ["version", "revision", "rules", "comment"])
    assert.strictEqual(written.revision, 5)
    assert.deepStrictEqual(written.rules.map(r => r.id), ["b", "a"])
    assert.strictEqual(written.rules[0].note, "b note")
    assert.strictEqual(written.rules[0].name, "B2")
    assert.deepStrictEqual(written.rules[1].future, { x: 1 })
    assert.strictEqual(written.rules[1].match.xwayland, true)
    assert.deepStrictEqual(Object.keys(written.rules[1]).slice(0, 4), ["id", "name", "enabled", "match"])
    assert.deepStrictEqual(plain(Model.validateDocument(written)).rules.map(r => r.status), ["ok", "ok"])
  },

  "serializeDocument writes only the keys of the chosen target and position type"() {
    const rule = base({ workspace: { type: "id", id: 4, resolver: "stale", arg: 2, slot: 3, hint: "kept" },
      position: { type: "center", x: 10, y: 20 } })
    const written = JSON.parse(Model.serializeDocument(null, [rule], 1))
    assert.deepStrictEqual(written.rules[0].workspace, { type: "id", id: 4, hint: "kept" })
    assert.deepStrictEqual(written.rules[0].position, { type: "center" })
    assert.deepStrictEqual(Object.keys(written), ["version", "revision", "rules"])
  },

  "serializeDocument passes an unvalidated rule through"() {
    const written = JSON.parse(Model.serializeDocument(doc([]), [{ id: "Bad", custom: 1 }, "x"], 2))
    assert.deepStrictEqual(written.rules, [{ id: "Bad", custom: 1 }, "x"])
  },

  "parseDocument refuses what the Lua decoder refuses"() {
    const code = text => plain(Model.parseDocument(text)).error || "ok"
    const nested = n => '{"version":1,"rules":[],"x":' + "[".repeat(n - 1) + "]".repeat(n - 1) + "}"
    assert.strictEqual(code(nested(64)), "ok")
    assert.strictEqual(code(nested(65)), "invalid-json")
    // Brackets inside strings, and escaped quotes, are not nesting.
    assert.strictEqual(code('{"version":1,"rules":[],"x":"' + "[\\\"".repeat(100) + '"}'), "ok")
    assert.strictEqual(code('{"version":1,"rules":[],"x":-1e308}'), "ok")
    assert.strictEqual(code('{"version":1,"rules":[],"x":-1e309}'), "invalid-json")
    assert.strictEqual(code('{"version":1,"rules":[],"\\udc00":1}'), "invalid-json")
    assert.strictEqual(code('{"version":1,"rules":[],"x":"\\ud83d\\ude00"}'), "ok")
    assert.strictEqual(code('{"version":1,"rules":[],"x":"\ud800"}'), "invalid-json")
    assert.strictEqual(code(" \n"), "invalid-json")
  },

  "savePlan writes revision + 1 over an unchanged file and keeps unknown fields"() {
    const text = JSON.stringify({ version: 1, revision: 4, comment: "kept", rules: [base({ id: "a", note: 1 })] })
    const rules = plain(Model.documentRules(Model.parseDocument(text)))
    const plan = plain(Model.savePlan({ revision: 4, text }, text, [...rules, base({ id: "b" })]))
    assert.deepStrictEqual([plan.ok, plan.revision, plan.backup], [true, 5, true])
    const written = JSON.parse(plan.text)
    assert.deepStrictEqual([written.revision, written.comment, written.rules[0].note, written.rules.length], [5, "kept", 1, 2])
    const fresh = plain(Model.savePlan({ revision: 0, text: null }, null, [base()]))
    assert.deepStrictEqual([fresh.ok, fresh.revision, fresh.backup], [true, 1, false])
  },

  "savePlan finds a conflict by content, not only by revision"() {
    const text = JSON.stringify({ version: 1, revision: 4, rules: [base()] })
    const edited = JSON.stringify({ version: 1, revision: 4, rules: [base({ name: "By hand" })] })
    for (const [b, current] of [[{ revision: 4, text }, edited], [{ revision: 4, text }, null], [{ revision: 0, text: null }, text],
      [{ revision: 0, text: null }, ""], [{ revision: 4, text }, text + " "], [null, text]])
      assert.deepStrictEqual(plain(Model.savePlan(b, current, [base()])), { ok: false, reason: "state.conflict.title", detail: "" })
    assert.strictEqual(Model.CONFLICT_KEY, "state.conflict.title")
  },

  "savePlan refuses a document the loader would reject whole"() {
    const many = n => Array.from({ length: n }, (_, i) => base({ id: "r" + i }))
    assert.strictEqual(Model.savePlan({ text: null }, null, many(200)).ok, true)
    assert.deepStrictEqual(plain(Model.savePlan({ text: null }, null, many(201))), { ok: false, reason: "save.tooManyRules", detail: "200" })
    // Bytes, not UTF-16 units: 400000 three-byte characters fit in 1 MiB as UTF-16 units, not as UTF-8.
    const wide = Array.from({ length: 4 }, (_, i) => base({ id: "w" + i, note: "€".repeat(100000) }))
    assert.ok(JSON.stringify(wide).length < 1048576)
    const big = plain(Model.savePlan({ text: null }, null, wide))
    assert.deepStrictEqual([big.ok, big.reason], [false, "save.tooLarge"])
    assert.ok(Number(big.detail) > 1048576)
    const top = JSON.stringify({ version: 1, revision: Number.MAX_SAFE_INTEGER, rules: [] })
    assert.deepStrictEqual(plain(Model.savePlan({ text: top }, top, [])), { ok: false, reason: "error.invalid-revision", detail: "" })
    const invalid = '{"version":1,"revision":"x","rules":[]}'
    assert.deepStrictEqual(plain(Model.savePlan({ text: invalid }, invalid, [])).reason, "error.invalid-revision")
    const deep = { version: 1, rules: [], x: JSON.parse("[".repeat(70) + "]".repeat(70)) }
    assert.deepStrictEqual(plain(Model.savePlan({ text: null }, null, [], deep)).reason, "error.invalid-json")
  },

  "savePlan carries an invalid rule over unchanged"() {
    const broken = { id: "Bad!", name: "kept", custom: [1] }
    const text = JSON.stringify({ version: 1, revision: 2, rules: [base({ id: "a" }), broken] })
    const rules = plain(Model.documentRules(Model.parseDocument(text)))
    const plan = plain(Model.savePlan({ revision: 2, text }, text, Model.moveRule(rules, 1, -1)))
    assert.strictEqual(plan.ok, true)
    assert.deepStrictEqual(JSON.parse(plan.text).rules[0], broken)
    assert.deepStrictEqual(plain(Model.parseDocument(plan.text).validation.rules.map(r => r.status)), ["invalid-id", "ok"])
  },

  "restorePlan restores a valid backup over the file as shown"() {
    const backup = JSON.stringify({ version: 1, revision: 6, rules: [] })
    assert.deepStrictEqual(plain(Model.restorePlan({ known: true, text: "" }, { ok: true, text: "" }, backup)),
      { ok: true, text: backup, revision: 6 })
    assert.strictEqual(Model.restorePlan({ known: false, text: null }, { ok: false, text: null }, backup).ok, true)
    for (const current of [{ ok: true, text: "{}" }, { ok: true, text: null }, { ok: false, text: null }])
      assert.strictEqual(Model.restorePlan({ known: true, text: "" }, current, backup).reason, "restore.changed")
    assert.strictEqual(Model.restorePlan({ known: false }, { ok: true, text: "" }, backup).reason, "restore.changed")
    for (const bad of [null, "", "{", '{"version":2,"rules":[]}'])
      assert.strictEqual(Model.restorePlan({ known: true, text: "" }, { ok: true, text: "" }, bad).reason, "restore.none")
  },

  "lockStep removes only a lock older than 30 seconds, and retries once"() {
    assert.strictEqual(Model.lockStep(0, "1000\n", 1031, false), "remove")
    assert.strictEqual(Model.lockStep(0, "1000\n", 1030, false), "busy")
    assert.strictEqual(Model.lockStep(0, "1000", 900, false), "busy")
    assert.strictEqual(Model.lockStep(1, "", 1031, false), "retry")
    assert.strictEqual(Model.lockStep(-2, "", 1031, false), "retry")
    for (const out of ["", "abc", "1e3", "-5", "<b>1</b>"]) assert.strictEqual(Model.lockStep(0, out, 1e9, false), "busy", out)
    for (const code of [0, 1]) assert.strictEqual(Model.lockStep(code, "1", 1e9, true), "busy")
  },

  "saveBlocker names why a save cannot start"() {
    assert.strictEqual(Model.saveBlocker({ busy: false, dirReady: true, fileState: "ok" }), "")
    assert.strictEqual(Model.saveBlocker({ busy: false, dirReady: true, fileState: "missing" }), "")
    assert.strictEqual(Model.saveBlocker({ busy: true, dirReady: true, fileState: "ok" }), "save.busy")
    assert.strictEqual(Model.saveBlocker({ busy: false, dirReady: false, fileState: "ok" }), "save.noStateDir")
    for (const fileState of ["invalid", "unsupported"])
      assert.strictEqual(Model.saveBlocker({ busy: false, dirReady: true, fileState }), "save.notEditable")
    assert.strictEqual(Model.saveBlocker(null), "save.noStateDir")
  },

  "panelMode keeps the panel's precedence"() {
    const ready = { ready: true, loaderKnown: true, conflict: false, fileState: "ok", editorOpen: false, loaderMissing: false, setupDismissed: false }
    const mode = over => Model.panelMode({ ...ready, ...over })
    assert.strictEqual(mode({}), "list")
    assert.strictEqual(mode({ ready: false, conflict: true }), "loading")
    assert.strictEqual(mode({ loaderKnown: false }), "loading")
    assert.strictEqual(mode({ conflict: true, fileState: "invalid", editorOpen: true }), "conflict")
    assert.strictEqual(mode({ fileState: "invalid", editorOpen: true }), "invalid")
    assert.strictEqual(mode({ fileState: "unsupported", editorOpen: true }), "unsupported")
    assert.strictEqual(mode({ editorOpen: true, loaderMissing: true }), "editor")
    assert.strictEqual(mode({ loaderMissing: true }), "setup")
    assert.strictEqual(mode({ loaderMissing: true, setupDismissed: true }), "list")
    assert.strictEqual(mode({ fileState: "missing" }), "list")
    assert.strictEqual(Model.panelMode(null), "loading")
  },

  "reapplyRule puts the edited rule back over the reloaded list"() {
    const a = valid("a"), b = valid("b")
    const edited = valid("a", { name: "Mine" })
    // Unchanged elsewhere: in place.
    assert.deepStrictEqual(plain(Model.reapplyRule([a, b], a, edited)), { index: 0, rule: plain(edited) })
    // Changed elsewhere: appended, with a new id since "a" is still taken.
    const other = plain(Model.reapplyRule([valid("a", { layout: "float" }), b], a, edited))
    assert.deepStrictEqual([other.index, other.rule.id, other.rule.name], [-1, "mine", "Mine"])
    // Deleted elsewhere: appended under its own id, which is free.
    assert.deepStrictEqual(plain(Model.reapplyRule([b], a, edited)), { index: -1, rule: plain(edited) })
    // A new rule whose id another rule took meanwhile.
    const fresh = plain(Model.reapplyRule([valid("mine")], null, valid("mine", { name: "Mine" })))
    assert.deepStrictEqual([fresh.index, fresh.rule.id], [-1, "mine-2"])
    // Renamed in the editor to an id another rule now holds: in place, with a free id.
    const renamed = plain(Model.reapplyRule([a, valid("c")], a, valid("c", { name: "C" })))
    assert.deepStrictEqual([renamed.index, renamed.rule.id], [0, "c-2"])
    const input = [a, b]
    const before = JSON.stringify(input)
    Model.reapplyRule(input, a, edited)
    assert.strictEqual(JSON.stringify(input), before)
  },

  "every save and restore key has its text in en.json"() {
    const keys = ["state.busyElsewhere", "save.savedNotReloaded", "save.tooManyRules", "save.tooLarge", "save.busy",
      "save.noStateDir", "save.notEditable", "save.writeFailed", "restore.changed", "restore.none", Model.CONFLICT_KEY,
      "confirm.replaceDraft.title", "confirm.replaceDraft.body", "confirm.replaceDraft.accept", "confirm.discardConflict.body",
      "state.conflict.kept", "action.reapply", "action.discardRule"]
    for (const key of keys) assert.strictEqual(typeof catalog[key], "string", key)
    for (const key of ["save.savedNotReloaded", "save.tooManyRules", "save.tooLarge", "state.conflict.kept"])
      assert.ok(catalog[key].includes("%1"), key)
  },

  "slugId derives a unique id from the name"() {
    assert.strictEqual(Model.slugId("Steam Big Picture", []), "steam-big-picture")
    assert.strictEqual(Model.slugId("  --Hello__World!!  ", []), "hello-world")
    assert.strictEqual(Model.slugId("Música", []), "m-sica")
    assert.strictEqual(Model.slugId("", []), "rule")
    assert.strictEqual(Model.slugId("日本", []), "rule")
    assert.strictEqual(Model.slugId("rule", ["rule"]), "rule-2")
    assert.strictEqual(Model.slugId("a", ["a", "a-2", "a-3"]), "a-4")
    const long = "x".repeat(60)
    assert.strictEqual(Model.slugId(long, []), "x".repeat(48))
    assert.strictEqual(Model.slugId(long, ["x".repeat(48)]), "x".repeat(46) + "-2")
    assert.strictEqual(Model.slugId("a".repeat(47) + "-b", []), "a".repeat(47))
    for (const id of [Model.slugId(long, ["x".repeat(48)]), Model.slugId("a b", [])]) assert.match(id, /^[a-z0-9][a-z0-9-]{0,47}$/)
  },

  "newRule is a valid default rule once it has a class"() {
    const rule = plain(Model.newRule("Files\u0007 app", ["files-app"]))
    assert.strictEqual(rule.id, "files-app-2")
    assert.strictEqual(rule.name, "Files app")
    assert.strictEqual(status({ ...rule, match: { "class": "^files$", title: "" } }), "ok")
    assert.strictEqual(plain(Model.newRule("é".repeat(100), [])).name, "é".repeat(80))
  },

  "capture of a tiled window on a regular workspace targets the monitor slot"() {
    const result = plain(Model.ruleFromWindow(win(), MONITORS, []))
    assert.deepStrictEqual(result.warnings, [])
    assert.deepStrictEqual(result.rule, { id: "org-example-editor", name: "org.example.Editor", enabled: true,
      match: { mode: "apps", classes: ["org.example.Editor"], title: "", titleMode: "exact", initial: false },
      workspace: { type: "monitor-slot", monitor: "desc:Example Display B2", slot: 3 },
      follow: true, layout: "default", size: null, position: { type: "none" }, monitor: null,
      fullscreen: false, maximize: false, pin: false, opacity: null, noInitialFocus: false })
    // The title is offered as written, for an exact title filter that starts off.
    assert.strictEqual(result.title, "notes.txt - Editor")
    assert.strictEqual(status(result.rule), "ok")
    assert.strictEqual(Model.previewCount(result.rule, [win(), win({ class: "org.example.Editor2" })]), 1)
    const titled = { ...result.rule, match: { ...result.rule.match, title: result.title } }
    assert.strictEqual(status(titled), "ok")
    assert.strictEqual(Model.previewCount(titled, [win(), win({ title: "notes.txt - Editor2" }), win({ title: "notesXtxt - Editor" })]), 1)
  },

  "capture of a floating window keeps size and monitor-relative position"() {
    const result = plain(Model.ruleFromWindow(win({ floating: true, at: [1700, -100], monitor: 1 }), MONITORS, []))
    assert.strictEqual(result.rule.layout, "float")
    assert.deepStrictEqual(result.rule.size, [1200, 800])
    assert.deepStrictEqual(result.rule.position, { type: "at", x: 100, y: 100 })
    assert.deepStrictEqual(result.warnings, [])
    assert.strictEqual(status(result.rule), "ok")
  },

  "capture clamps a position outside the monitor and warns"() {
    const result = plain(Model.ruleFromWindow(win({ floating: true, at: [1500, -250] }), MONITORS, []))
    assert.deepStrictEqual(result.rule.position, { type: "at", x: 0, y: 0 })
    assert.deepStrictEqual(result.warnings, ["capture-position-clamped"])
    assert.strictEqual(status(result.rule), "ok")
  },

  "capture of a special workspace window targets the special workspace"() {
    const result = plain(Model.ruleFromWindow(win({ workspace: { id: -98, name: "special:scratchpad" }, pinned: true }), MONITORS, []))
    assert.deepStrictEqual(result.rule.workspace, { type: "special", name: "scratchpad" })
    assert.strictEqual(result.rule.pin, true)
    const odd = plain(Model.ruleFromWindow(win({ workspace: { id: -5, name: "special:a b" } }), MONITORS, []))
    assert.deepStrictEqual([odd.rule.workspace, odd.warnings], [{ type: "none" }, ["capture-workspace-unsupported"]])
  },

  "capture without the window's monitor falls back to the workspace id"() {
    const result = plain(Model.ruleFromWindow(win({ monitor: 7, floating: true }), MONITORS, []))
    assert.deepStrictEqual(result.rule.workspace, { type: "id", id: 13 })
    assert.deepStrictEqual(result.rule.position, { type: "none" })
    assert.strictEqual(status(result.rule), "ok")
  },

  "capture maps the fullscreen mask and takes a free id"() {
    assert.deepStrictEqual(["fullscreen", "maximize"].map(k => Model.ruleFromWindow(win({ fullscreen: 2 }), MONITORS, []).rule[k]), [true, false])
    assert.deepStrictEqual(["fullscreen", "maximize"].map(k => Model.ruleFromWindow(win({ fullscreen: 1 }), MONITORS, []).rule[k]), [false, true])
    assert.deepStrictEqual(["fullscreen", "maximize"].map(k => Model.ruleFromWindow(win({ fullscreen: 3 }), MONITORS, []).rule[k]), [true, false])
    assert.strictEqual(Model.ruleFromWindow(win(), MONITORS, ["org-example-editor"]).rule.id, "org-example-editor-2")
    const parsed = Model.parseClients(JSON.stringify([win({ class: "a.b(c)+" })]))
    const rule = plain(Model.ruleFromWindow(parsed[0], Model.parseMonitors(JSON.stringify(MONITORS)), [])).rule
    assert.deepStrictEqual(rule.match.classes, ["a.b(c)+"])
    assert.deepStrictEqual(plain(Model.compileMatch(rule.match)), { "class": "^(a\\.b\\(c\\)\\+)$" })
    assert.strictEqual(Model.previewCount(rule, parsed), 1)
  },

  "parseClients bounds the list and every field"() {
    assert.deepStrictEqual(plain(Model.parseClients("garbage")), [])
    assert.deepStrictEqual(plain(Model.parseClients("{}")), [])
    const list = Model.parseClients(JSON.stringify([win(), 7, null, win({ class: "" }), win({ class: 5 }),
      win({ class: "x".repeat(513) }), win({ title: "t".repeat(600), pid: -1, monitor: 1.5, size: [1, "x"], address: "nope" })]))
    assert.strictEqual(list.length, 2)
    assert.strictEqual(list[1].title.length, 512)
    assert.deepStrictEqual(plain([list[1].pid, list[1].monitor, list[1].size, list[1].address]), [0, -1, null, ""])
    assert.deepStrictEqual(plain(list[0]), { address: "0xabc", class: "org.example.Editor", title: "notes.txt - Editor",
      initialClass: "", initialTitle: "", floating: false, size: [1200, 800], at: [1700, -150], monitor: 1, workspace: { id: 13, name: "13" },
      fullscreen: 0, pinned: false, pid: 4242 })
    assert.strictEqual(Model.parseClients(JSON.stringify(Array.from({ length: 600 }, () => win()))).length, 512)
    // A cut never splits a surrogate pair.
    assert.strictEqual(Model.parseClients(JSON.stringify([win({ title: "a" + "😀".repeat(300) })]))[0].title.length, 511)
  },

  "parseActiveWindow returns one client or null"() {
    assert.strictEqual(Model.parseActiveWindow("{}"), null)
    assert.strictEqual(Model.parseActiveWindow(""), null)
    assert.strictEqual(Model.parseActiveWindow("[]"), null)
    assert.strictEqual(Model.parseActiveWindow(JSON.stringify(win())).class, "org.example.Editor")
  },

  "parseMonitors bounds the list"() {
    const list = plain(Model.parseMonitors(JSON.stringify([...MONITORS, { id: "x", name: "A" }, { id: 3 }, { id: 4, name: "B", scale: -1 }])))
    assert.deepStrictEqual(list.map(m => m.name), ["eDP-1", "DP-2", "B"])
    assert.strictEqual(list[2].scale, 1)
    assert.strictEqual(list[2].description, "")
    const many = Array.from({ length: 20 }, (_, i) => ({ ...MONITORS[0], id: i }))
    assert.strictEqual(Model.parseMonitors(JSON.stringify(many)).length, 16)
  },

  "parseDescribe reads the loader state and rejects anything else"() {
    for (const text of ["", "garbage", "error: [string \"return x\"]:1: attempt to index a nil value", '{"loaded":false}\n',
      "[]", '"text"', '{"loaded":"yes"}', '{"loaded":true} trailing', null])
      assert.deepStrictEqual(plain(Model.parseDescribe(text)), { loaded: false }, String(text))
    const errors = Array.from({ length: 250 }, (_, i) => ({ id: i % 2 ? "r" + i : null, code: "resolver-failed", detail: "d".repeat(600) }))
    const text = JSON.stringify({ loaded: true, api: 1, loaderVersion: "1.0.0", schema: 1, revision: 7, rules: 4, dynamic: 2,
      counters: { opened: 41, matched: 17, moved: 12, extra: 3 },
      resolvers: [{ name: "external-slot", label: "External display slot", argLabel: "Slot" }, { name: "Bad Name" }, 3],
      errors: [...errors, { code: 5 }] }) + "\n"
    const d = plain(Model.parseDescribe(text))
    assert.deepStrictEqual([d.loaded, d.api, d.loaderVersion, d.schema, d.revision, d.rules, d.dynamic], [true, 1, "1.0.0", 1, 7, 4, 2])
    assert.deepStrictEqual(d.counters, { opened: 41, matched: 17, moved: 12 })
    assert.deepStrictEqual(d.resolvers, [{ name: "external-slot", label: "External display slot", argLabel: "Slot" }])
    assert.strictEqual(d.errors.length, 200)
    assert.deepStrictEqual([d.errors[0].id, d.errors[1].id, d.errors[0].detail.length], [null, "r1", 512])
    const sparse = plain(Model.parseDescribe('{"loaded":true,"rules":-1,"revision":"7"}'))
    assert.deepStrictEqual(sparse, { loaded: true, api: 0, loaderVersion: "", schema: 0, revision: null, rules: 0, dynamic: 0,
      counters: { opened: 0, matched: 0, moved: 0 }, resolvers: [], errors: [] })
    // Counters and the API version are whole numbers from 0; anything else reads as 0.
    const odd = plain(Model.parseDescribe(JSON.stringify({ loaded: true, api: "2",
      counters: { opened: -1, matched: 1.5, moved: 2 ** 60 } })))
    assert.deepStrictEqual([odd.api, odd.counters], [0, { opened: 0, matched: 0, moved: 0 }])
    assert.deepStrictEqual(plain(Model.parseDescribe('{"loaded":true,"counters":[1,2,3]}')).counters, { opened: 0, matched: 0, moved: 0 })
  },

  "parseConfigErrors keeps trimmed non-empty lines"() {
    assert.deepStrictEqual(plain(Model.parseConfigErrors("\n\n")), [])
    assert.deepStrictEqual(plain(Model.parseConfigErrors("  a: bad  \n\n b \n")), ["a: bad", "b"])
    assert.strictEqual(Model.parseConfigErrors(Array.from({ length: 80 }, (_, i) => "e" + i).join("\n")).length, 50)
    assert.strictEqual(Model.parseConfigErrors("x".repeat(900))[0].length, 512)
  },

  "previewCount uses full-match semantics"() {
    const clients = Model.parseClients(JSON.stringify([win({ class: "steam" }), win({ class: "steam_app_42", title: "Game" }),
      win({ class: "steamwebhelper" }), win({ class: "xsteam" })]))
    const rule = (cls, title = "") => ({ match: { "class": cls, title } })
    assert.strictEqual(Model.previewCount(rule("steam"), clients), 1)
    assert.strictEqual(Model.previewCount(rule("steam|steam_app_.+"), clients), 2)
    assert.strictEqual(Model.previewCount(rule("steam.*"), clients), 3)
    assert.strictEqual(Model.previewCount(rule("steam.*", "Game"), clients), 1)
    assert.strictEqual(Model.previewCount(rule("steam.*", "Gam"), clients), 0)
    assert.strictEqual(Model.previewCount(rule("(?P<n>steam)"), clients), 1)
    assert.strictEqual(Model.previewCount(rule("(?<=x)steam"), clients), 0)
    assert.strictEqual(Model.previewCount(rule("("), clients), 0)
    assert.strictEqual(Model.previewCount(rule("steam.*", "(?!x)"), clients), 0)
    assert.strictEqual(Model.previewCount(rule("a.*"), Array.from({ length: 600 }, () => ({ class: "ab", title: "" }))), 512)
    assert.strictEqual(Model.previewCount(null, clients), 0)
  },

  "targetSummary gives the key and arguments"() {
    const summary = (workspace, resolvers) => plain(Model.targetSummary(base({ workspace }), resolvers))
    assert.deepStrictEqual(summary({ type: "none" }), { key: "target.none", args: [] })
    assert.deepStrictEqual(summary({ type: "id", id: 13 }), { key: "target.workspace", args: ["13"] })
    assert.deepStrictEqual(summary({ type: "special", name: "scratchpad" }), { key: "target.special", args: ["scratchpad"] })
    assert.deepStrictEqual(summary({ type: "monitor-slot", monitor: "desc:Example Display B2", slot: 3 }),
      { key: "target.monitorSlot", args: ["3", "Example Display B2"] })
    assert.deepStrictEqual(summary({ type: "resolver", resolver: "external-slot", arg: 2 }),
      { key: "target.resolver", args: ["external-slot", "2"] })
    assert.deepStrictEqual(summary({ type: "resolver", resolver: "external-slot", arg: 2 }, [{ name: "external-slot", label: "External display slot" }]),
      { key: "target.resolver", args: ["External display slot", "2"] })
    assert.deepStrictEqual(plain(Model.targetSummary(null)), { key: "target.none", args: [] })
  },

  "targetBadge gives a compact key and bounded arguments"() {
    const badge = workspace => plain(Model.targetBadge(base({ workspace })))
    assert.deepStrictEqual(badge({ type: "none" }), { key: "badge.none", args: [] })
    assert.deepStrictEqual(badge({ type: "id", id: 1 }), { key: "badge.workspace", args: ["1"] })
    assert.deepStrictEqual(badge({ type: "special", name: "scratchpad" }), { key: "badge.special", args: ["scratchpad"] })
    assert.deepStrictEqual(badge({ type: "monitor-slot", monitor: "desc:Example Display B2", slot: 3 }),
      { key: "badge.monitorSlot", args: ["3", "Example Dis\u2026"] })
    assert.deepStrictEqual(badge({ type: "monitor-slot", monitor: "desc:Short", slot: 1 }), { key: "badge.monitorSlot", args: ["1", "Short"] })
    assert.deepStrictEqual(badge({ type: "resolver", resolver: "external-slot", arg: 3 }), { key: "badge.resolver", args: ["external slot", "3"] })
    // Markup-shaped text stays as written, on one line.
    assert.deepStrictEqual(badge({ type: "monitor-slot", monitor: "desc:<b>x</b>\n", slot: 2 }).args, ["2", "<b>x</b>"])
    assert.deepStrictEqual(plain(Model.targetBadge(null)), { key: "badge.none", args: [] })
    const placeholders = { "badge.none": 0, "badge.workspace": 1, "badge.special": 1, "badge.monitorSlot": 2, "badge.resolver": 2 }
    for (const [key, n] of Object.entries(placeholders)) {
      assert.strictEqual(typeof catalog[key], "string", key)
      for (let i = 1; i <= n; i++) assert.ok(catalog[key].includes("%" + i), key + " %" + i)
    }
  },

  "targetGlyph has one glyph per target type and a fallback"() {
    const types = ["none", "id", "special", "monitor-slot", "resolver", "invalid"]
    const glyphs = types.map(type => Model.targetGlyph(type))
    assert.strictEqual(new Set(glyphs).size, types.length)
    for (const glyph of glyphs) assert.strictEqual([...glyph].length, 1)
    for (const odd of ["", "toString", "__proto__", null, 5]) assert.strictEqual(Model.targetGlyph(odd), Model.targetGlyph("none"))
  },

  "listRows gives each row its target type and badge"() {
    const rows = plain(Model.listRows([
      valid("a", { workspace: { type: "id", id: 4 } }),
      valid("b", { workspace: { type: "monitor-slot", monitor: "desc:Example Panel A1", slot: 2 } }),
      { id: "c", name: "C", match: { "class": "(?<=x)" } }], [], []))
    assert.deepStrictEqual(rows.map(r => r.target), ["id", "monitor-slot", "invalid"])
    assert.deepStrictEqual(rows.map(r => r.badge), [{ key: "badge.workspace", args: ["4"] },
      { key: "badge.monitorSlot", args: ["2", "Example Pan\u2026"] }, null])
  },

  "summaryCounts counts the strip over the list"() {
    const list = [
      valid("a", { workspace: { type: "monitor-slot", monitor: "desc:Example Panel A1", slot: 2 } }),
      valid("b", { enabled: false, workspace: { type: "resolver", resolver: "external-slot", arg: 1 } }),
      valid("c", { workspace: { type: "resolver", resolver: "external-slot", arg: 1 } }),
      valid("d"),
      { id: "e", name: "E", match: { "class": "(?<=x)" } }]
    const loader = Model.parseDescribe(JSON.stringify({ loaded: true, counters: { moved: 9 },
      errors: [{ id: "c", index: 3, code: "resolver-failed" }, { id: null, index: null, code: "capability-missing" }] }))
    const rows = Model.listRows(list, [], loader.errors)
    assert.deepStrictEqual(plain(Model.summaryCounts(rows, loader, "")), { total: 5, enabled: 3, dynamic: 2, moved: 9, errors: 3 })
    // Without a loader: no moved count and no loader errors; a file error counts once.
    assert.deepStrictEqual(plain(Model.summaryCounts(Model.listRows(list, [], []), { loaded: false }, "using-backup")),
      { total: 5, enabled: 3, dynamic: 2, moved: null, errors: 2 })
    assert.deepStrictEqual(plain(Model.summaryCounts(null, null, null)), { total: 0, enabled: 0, dynamic: 0, moved: null, errors: 0 })
    // Rows from a Qt list.
    assert.strictEqual(Model.summaryCounts({ length: 1, 0: rows[0] }, loader, "").enabled, 1)
  },

  "heroState names the panel state, first match wins"() {
    const state = over => plain(Model.heroState({ loaderKnown: true, fileState: "ok", loaderLoaded: true, errors: 0, ...over }))
    assert.deepStrictEqual(state({ loaderKnown: false, fileState: "invalid" }), { key: "", count: 0 })
    assert.deepStrictEqual(state({ fileState: "invalid", loaderLoaded: false }), { key: "hero.invalid", count: 0 })
    assert.deepStrictEqual(state({ fileState: "unsupported" }), { key: "hero.unsupported", count: 0 })
    assert.deepStrictEqual(state({ loaderLoaded: false, errors: 2 }), { key: "hero.noLoader", count: 0 })
    assert.deepStrictEqual(state({ errors: 2 }), { key: "hero.errors", count: 2 })
    assert.deepStrictEqual(state({ errors: -1 }), { key: "hero.ok", count: 0 })
    assert.deepStrictEqual(state({ fileState: "missing" }), { key: "hero.ok", count: 0 })
    assert.deepStrictEqual(plain(Model.heroState(null)), { key: "", count: 0 })
    for (const key of ["hero.invalid", "hero.unsupported", "hero.noLoader", "hero.ok", "hero.meta"])
      assert.strictEqual(typeof catalog[key], "string", key)
    assert.ok(catalog["hero.errors"].one.includes("%1") && catalog["hero.errors"].other.includes("%1"))
    assert.ok(catalog["hero.meta"].includes("%1") && catalog["hero.meta"].includes("%2"))
  },

  "every target key has its text and placeholders in en.json"() {
    const placeholders = { "target.none": 0, "target.workspace": 1, "target.special": 1, "target.monitorSlot": 2, "target.resolver": 2 }
    for (const [key, n] of Object.entries(placeholders)) {
      assert.strictEqual(typeof catalog[key], "string", key)
      for (let i = 1; i <= n; i++) assert.ok(catalog[key].includes("%" + i), key + " %" + i)
    }
  },

  "errorKey and warningKey fall back for unknown codes"() {
    assert.strictEqual(Model.errorKey("invalid-id"), "error.invalid-id")
    assert.strictEqual(Model.errorKey("resolver-failed"), "error.resolver-failed")
    for (const code of ["made-up", "", null, 5, "__proto__", "constructor", "<b>x</b>"]) assert.strictEqual(Model.errorKey(code), "error.unknown")
    assert.strictEqual(Model.warningKey("warn-geometry-not-floating"), "warning.warn-geometry-not-floating")
    assert.strictEqual(Model.warningKey("toString"), "warning.unknown")
  },

  "every code Model.js can return has its text in en.json"() {
    const codes = [...Model.FILE_CODES, ...Model.RULE_CODES, ...Model.LOADER_CODES]
    for (const entry of conformance.cases) {
      assert.ok(entry.expect.file === "ok" || codes.includes(entry.expect.file), entry.expect.file)
      for (const code of entry.expect.rules) assert.ok(code === "ok" || codes.includes(code), code)
    }
    for (const code of [...codes, "unknown"]) assert.strictEqual(typeof catalog["error." + code], "string", code)
    for (const code of [...Model.WARNING_CODES, "unknown"]) assert.strictEqual(typeof catalog["warning." + code], "string", code)
    for (const code of codes) assert.strictEqual(catalog[Model.errorKey(code)], catalog["error." + code])
  },

  "the catalog is flat with plural entries for counted strings"() {
    for (const [key, value] of Object.entries(catalog)) {
      if (typeof value === "string") { assert.ok(value.length > 0, key); continue }
      assert.deepStrictEqual(Object.keys(value).sort(), ["one", "other"], key)
      assert.ok(value.one.includes("%1") && value.other.includes("%1"), key)
    }
    assert.ok(catalog["preview.matches"].other.includes("approximate"))
  }
})

// ---------- Panel helpers ----------

const valid = (id, over = {}) => base({ id, name: id.toUpperCase(), ...over })

Object.assign(tests, {
  "stateDirectory follows XDG_STATE_HOME only when it is absolute"() {
    assert.strictEqual(Model.stateDirectory("/x/state/", "/home/u", "p.id"), "/x/state/omarchy/p.id")
    assert.strictEqual(Model.stateDirectory("", "/home/u", "p.id"), "/home/u/.local/state/omarchy/p.id")
    assert.strictEqual(Model.stateDirectory("relative", "/home/u", "p.id"), "/home/u/.local/state/omarchy/p.id")
    assert.strictEqual(Model.stateDirectory(undefined, "/home/u", "p.id"), "/home/u/.local/state/omarchy/p.id")
  },

  "manifestVersion reads the plugin's own manifest and rejects anything else"() {
    const manifest = fs.readFileSync(path.join(pluginDir, "manifest.json"), "utf8")
    assert.strictEqual(Model.manifestVersion(manifest), JSON.parse(manifest).version)
    for (const text of ["", "{", "[]", '{"version":1}', '{"version":"<b>x</b>"}']) assert.strictEqual(Model.manifestVersion(text), "")
  },

  "the load block is the design's and names the plugin path"() {
    assert.match(Model.LOAD_BLOCK, /^do\n/)
    assert.match(Model.LOAD_BLOCK, /\/omarchy\/plugins\/io\.github\.ltecosta\.window-rules\/hypr\/window-rules\.lua/)
    assert.match(Model.LOAD_BLOCK, /window_rules\.load\(\)\n    end\n  end\nend$/)
    assert.match(Model.LOAD_BLOCK, /pcall\(dofile, path\)/)
    assert.match(Model.LOAD_BLOCK, /config:sub\(1, 1\) ~= "\/"/)
    assert.strictEqual(Model.LOAD_BLOCK, [
      "do",
      '  local home = os.getenv("HOME") or ""',
      '  local config = os.getenv("XDG_CONFIG_HOME")',
      '  if not config or config:sub(1, 1) ~= "/" then config = home .. "/.config" end',
      '  local path = config .. "/omarchy/plugins/io.github.ltecosta.window-rules/hypr/window-rules.lua"',
      '  local file = io.open(path, "r")',
      "  if file then",
      "    file:close()",
      "    local ok, window_rules = pcall(dofile, path)",
      '    if ok and type(window_rules) == "table" then',
      '      -- window_rules.register_resolver(...)  -- optional, see "Resolvers"',
      "      window_rules.load()",
      "    end",
      "  end",
      "end"].join("\n"))
  },

  "documentRules keeps invalid rules as written and normalizes valid ones"() {
    const text = JSON.stringify(doc([{ id: "a", name: "A", match: { "class": "^a$" } }, { id: "B!", name: "bad", extra: 1 }]))
    const rules = plain(Model.documentRules(Model.parseDocument(text)))
    assert.strictEqual(rules.length, 2)
    assert.strictEqual(rules[0].layout, "default")
    assert.deepStrictEqual(rules[1], { id: "B!", name: "bad", extra: 1 })
    assert.deepStrictEqual(plain(Model.documentRules(Model.parseDocument("{"))), [])
    assert.deepStrictEqual(plain(Model.documentRules(Model.parseDocument(""))), [])
  },

  "listRows describes each rule, marks loader errors and keeps markup as text"() {
    const markup = '<img src="https://example.invalid/t">'
    const rows = plain(Model.listRows([
      valid("steam", { name: markup, enabled: false, workspace: { type: "resolver", resolver: "external-slot", arg: 3 } }),
      { id: "broken", name: "Broken", match: { "class": "(?<=x)" } },
      "not a rule"
    ], [{ name: "external-slot", label: "External slot", argLabel: "Slot" }], [{ id: "steam", code: "resolver-failed" }, { id: null, code: "x" }]))
    assert.strictEqual(rows[0].name, markup)
    assert.strictEqual(rows[0].enabled, false)
    assert.strictEqual(rows[0].valid, true)
    assert.strictEqual(rows[0].loaderError, true)
    assert.deepStrictEqual(rows[0].summary, { key: "target.resolver", args: ["External slot", "3"] })
    assert.strictEqual(rows[1].valid, false)
    assert.strictEqual(rows[1].errorKey, "error.invalid-class")
    assert.strictEqual(rows[1].summary, null)
    assert.strictEqual(rows[1].loaderError, false)
    assert.deepStrictEqual([rows[2].id, rows[2].name, rows[2].errorKey], ["", "", "error.invalid-rule"])
    assert.deepStrictEqual(rows.map(r => r.index), [0, 1, 2])
  },

  "fill replaces every placeholder once and leaves arguments as written"() {
    assert.strictEqual(Model.fill("%1 — %2", ["a%2", "<b>t</b>"]), "a%2 — <b>t</b>")
    assert.strictEqual(Model.fill("Slot %1 on %2", ["3"]), "Slot 3 on %2")
    assert.strictEqual(Model.fill("Anywhere", []), "Anywhere")
    assert.strictEqual(Model.fill("%1%1", [7]), "77")
    // A Qt list reaches JS as an array-like object, not an Array.
    assert.strictEqual(Model.fill("Workspace %1", { 0: 13, length: 1 }), "Workspace 13")
    assert.strictEqual(Model.fill(catalog["picker.option"], ["term", "~"]), "term — ~")
  },

  "list edits return new lists and leave the input alone"() {
    const list = [valid("a"), valid("b"), valid("c")]
    const before = JSON.stringify(list)
    assert.deepStrictEqual(plain(Model.moveRule(list, 0, 1)).map(r => r.id), ["b", "a", "c"])
    assert.deepStrictEqual(plain(Model.moveRule(list, 0, -1)).map(r => r.id), ["a", "b", "c"])
    assert.deepStrictEqual(plain(Model.moveRule(list, 2, 1)).map(r => r.id), ["a", "b", "c"])
    assert.strictEqual(plain(Model.setRuleEnabled(list, 1, false))[1].enabled, false)
    const copied = plain(Model.duplicateRule(list, 0))
    assert.deepStrictEqual(copied.map(r => r.id), ["a", "a-2", "b", "c"])
    assert.strictEqual(copied[1].name, "A")
    assert.deepStrictEqual(plain(Model.removeRule(list, 1)).map(r => r.id), ["a", "c"])
    assert.deepStrictEqual(plain(Model.putRule(list, 1, valid("x"))).map(r => r.id), ["a", "x", "c"])
    assert.deepStrictEqual(plain(Model.putRule(list, -1, valid("x"))).map(r => r.id), ["a", "b", "c", "x"])
    assert.deepStrictEqual(plain(Model.ruleIds(list, 1)), ["a", "c"])
    assert.strictEqual(JSON.stringify(list), before)
    assert.ok(Model.sameJson(list, JSON.parse(before)))
    assert.ok(!Model.sameJson(list, Model.moveRule(list, 0, 1)))
    assert.ok(Model.sameJson({ a: 1, b: { c: [1, { d: 2, e: 3 }] } }, { b: { c: [1, { e: 3, d: 2 }] }, a: 1 }))
    assert.ok(!Model.sameJson({ a: [1, 2] }, { a: [2, 1] }))
  },

  "checkDraft reports the first failure, its field, pattern errors and duplicate ids"() {
    const list = [valid("a"), valid("b")]
    assert.deepStrictEqual(plain(Model.checkDraft(list, 0, valid("a"))),
      { ok: true, status: "ok", field: "", classError: "", titleError: "", warnings: [] })
    const fresh = plain(Model.checkDraft(list, -1, plain(Model.newRule("", []))))
    assert.deepStrictEqual([fresh.ok, fresh.status, fresh.field, fresh.classError], [false, "invalid-name", "name", "invalid-class"])
    assert.deepStrictEqual(plain(Model.checkDraft(list, 0, valid("b"))).status, "duplicate-id")
    assert.deepStrictEqual(plain(Model.checkDraft(list, -1, valid("b"))).field, "id")
    const broken = plain(Model.checkDraft(list, 0, valid("a", { match: { "class": "(", title: "[" } })))
    assert.deepStrictEqual([broken.ok, broken.status, broken.classError, broken.titleError], [false, "ok", "pattern-syntax", "pattern-syntax"])
    const geometry = plain(Model.checkDraft(list, 0, valid("a", { size: [100, 100] })))
    assert.deepStrictEqual([geometry.ok, geometry.warnings], [true, ["warn-geometry-not-floating"]])
    assert.strictEqual(plain(Model.checkDraft(list, 0, valid("a", { fullscreen: true, maximize: true }))).field, "flags")
    for (const code of Object.keys(Model.ERROR_FIELDS)) assert.ok(Model.RULE_CODES.includes(code), code)
  },

  "workspaceFor keeps what fits and starts new targets on the first choice"() {
    assert.deepStrictEqual(plain(Model.workspaceFor("none", { type: "id", id: 4 })), { type: "none" })
    assert.deepStrictEqual(plain(Model.workspaceFor("id", { type: "id", id: 4 })), { type: "id", id: 4 })
    assert.deepStrictEqual(plain(Model.workspaceFor("id", { type: "none" })), { type: "id", id: 1 })
    assert.deepStrictEqual(plain(Model.workspaceFor("special", {})), { type: "special", name: "scratchpad" })
    assert.deepStrictEqual(plain(Model.workspaceFor("monitor-slot", {}, "desc:Example Panel A1")),
      { type: "monitor-slot", monitor: "desc:Example Panel A1", slot: 1 })
    assert.deepStrictEqual(plain(Model.workspaceFor("resolver", {}, "", "external-slot")),
      { type: "resolver", resolver: "external-slot", arg: 1 })
    for (const type of Model.WORKSPACE_TYPES) {
      const rule = base({ workspace: Model.workspaceFor(type, {}, "desc:Example Panel A1", "external-slot") })
      assert.strictEqual(validate([rule]).rules[0].status, "ok", type)
    }
  },

  "monitorOptions and resolverOptions keep a value that is no longer offered"() {
    assert.deepStrictEqual(plain(Model.monitorOptions(MONITORS, "desc:Gone Display")), [
      { value: "desc:Example Panel A1", label: "Example Panel A1" },
      { value: "desc:Example Display B2", label: "Example Display B2" },
      { value: "desc:Gone Display", label: "Gone Display" }])
    assert.deepStrictEqual(plain(Model.monitorOptions([{ description: "" }, MONITORS[0], MONITORS[0]], null)),
      [{ value: "desc:Example Panel A1", label: "Example Panel A1" }])
    assert.deepStrictEqual(plain(Model.monitorOptions({ length: 1, 0: MONITORS[1] }, null)),
      [{ value: "desc:Example Display B2", label: "Example Display B2" }])
    assert.deepStrictEqual(plain(Model.monitorOptions({ length: -1 }, null)), [])
    assert.deepStrictEqual(plain(Model.monitorOptions(null, null)), [])
    const resolvers = [{ name: "external-slot", label: "External slot", argLabel: "Slot" }, { name: "plain", label: "", argLabel: "" }]
    assert.deepStrictEqual(plain(Model.resolverOptions(resolvers, "missing")), [
      { value: "external-slot", label: "External slot", argLabel: "Slot" },
      { value: "plain", label: "plain", argLabel: "" },
      { value: "missing", label: "missing", argLabel: "" }])
    assert.strictEqual(Model.resolverArgLabel(resolvers, "external-slot"), "Slot")
    assert.strictEqual(Model.resolverArgLabel(resolvers, "missing"), "")
  },

  "loaderNotes warns about a stale revision or another loader version"() {
    const loader = { loaded: true, loaderVersion: "1.0.0", revision: 8 }
    assert.deepStrictEqual(plain(Model.loaderNotes(loader, 8, "1.0.0")), [])
    assert.deepStrictEqual(plain(Model.loaderNotes({ loaded: false }, 8, "1.0.0")), [])
    assert.deepStrictEqual(plain(Model.loaderNotes({ ...loader, revision: 7, loaderVersion: "0.9.0" }, 8, "1.0.0")), [
      { key: "loader.revisionMismatch", args: ["7", "8"] },
      { key: "loader.versionMismatch", args: ["0.9.0", "1.0.0"] }])
    for (const note of Model.loaderNotes({ ...loader, revision: 7, loaderVersion: "0.9.0" }, 8, "1.0.0"))
      assert.strictEqual(typeof catalog[note.key], "string", note.key)
  }
})

// ---------- QML boundary, loader errors, patterns and repair ----------

// A Qt list as QML hands it to JavaScript: indexed and counted, not an Array.
const qt = list => {
  const out = { length: list.length }
  list.forEach((value, i) => { out[i] = value })
  return out
}

Object.assign(tests, {
  "the picker path with Qt lists captures what the direct path captures"() {
    for (const client of [win(), win({ floating: true, at: [1700, -100] }), win({ floating: true, at: [1500, -250] })]) {
      const direct = plain(Model.ruleFromWindow(client, MONITORS, ["org-example-editor"]))
      const qtClient = { ...client, at: qt(client.at), size: qt(client.size) }
      const picked = plain(Model.ruleFromWindow(qtClient, qt(MONITORS), qt(["org-example-editor"])))
      assert.deepStrictEqual(picked, direct)
    }
    // The case that lost the display and the position.
    const floating = plain(Model.ruleFromWindow({ ...win({ floating: true, at: [1605, -190] }), at: qt([1605, -190]), size: qt([1200, 800]) },
      { 0: MONITORS[1], length: 1 }, []))
    assert.deepStrictEqual(floating.rule.workspace, { type: "monitor-slot", monitor: "desc:Example Display B2", slot: 3 })
    assert.deepStrictEqual(floating.rule.position, { type: "at", x: 5, y: 10 })
    assert.deepStrictEqual(floating.rule.size, [1200, 800])
    assert.strictEqual(Model.ruleFromWindow(win(), qt(MONITORS), qt(["org-example-editor"])).rule.id, "org-example-editor-2")
  },

  "list edits, ids and options read Qt lists"() {
    const list = [valid("a"), valid("b"), valid("c")]
    assert.deepStrictEqual(plain(Model.ruleIds(qt(list), 1)), ["a", "c"])
    assert.deepStrictEqual(plain(Model.moveRule(qt(list), 0, 1)).map(r => r.id), ["b", "a", "c"])
    assert.strictEqual(plain(Model.setRuleEnabled(qt(list), 2, false))[2].enabled, false)
    assert.deepStrictEqual(plain(Model.duplicateRule(qt(list), 1)).map(r => r.id), ["a", "b", "b-2", "c"])
    assert.deepStrictEqual(plain(Model.removeRule(qt(list), 0)).map(r => r.id), ["b", "c"])
    assert.deepStrictEqual(plain(Model.putRule(qt(list), -1, valid("x"))).map(r => r.id), ["a", "b", "c", "x"])
    assert.deepStrictEqual(plain(Model.reapplyRule(qt(list), list[0], valid("a", { name: "Mine" }))).index, 0)
    assert.strictEqual(Model.slugId("a", qt(["a", "a-2"])), "a-3")
    assert.strictEqual(Model.newRule("B", qt(["b"])).id, "b-2")
    const resolvers = [{ name: "external-slot", label: "External slot", argLabel: "Slot" }]
    assert.deepStrictEqual(plain(Model.resolverOptions(qt(resolvers), "")), [{ value: "external-slot", label: "External slot", argLabel: "Slot" }])
    assert.strictEqual(Model.resolverArgLabel(qt(resolvers), "external-slot"), "Slot")
    assert.deepStrictEqual(plain(Model.targetSummary(valid("r", { workspace: { type: "resolver", resolver: "external-slot", arg: 2 } }), qt(resolvers))),
      { key: "target.resolver", args: ["External slot", "2"] })
    const parsed = Model.parseDocument(JSON.stringify(doc(list)))
    assert.deepStrictEqual(plain(Model.documentRules({ ...parsed, validation: { ...parsed.validation, rules: qt(parsed.validation.rules) } })).map(r => r.id),
      ["a", "b", "c"])
  },

  "previewCount, listRows, checkDraft and the save path read Qt lists"() {
    const clients = Model.parseClients(JSON.stringify([win({ class: "steam" }), win({ class: "other" })]))
    assert.strictEqual(Model.previewCount({ match: { "class": "steam", title: "" } }, qt(clients)), 1)
    const rows = plain(Model.listRows(qt([valid("a"), valid("b")]), qt([]), qt([{ id: "b", index: 2, code: "resolver-failed", detail: "boom" }])))
    assert.deepStrictEqual(rows.map(r => r.errors), [[], [{ key: "error.resolver-failed", detail: "boom" }]])
    // A size that came back from QML as a Qt list is a size.
    const sized = valid("a", { layout: "float", size: qt([800, 600]) })
    assert.strictEqual(plain(Model.checkDraft(qt([valid("a")]), 0, sized)).ok, true)
    assert.deepStrictEqual(plain(Model.putRule([valid("a")], 0, sized))[0].size, [800, 600])
    const text = Model.serializeDocument({ version: 1, rules: qt([valid("a", { note: 1 })]) }, qt([valid("a")]), 2)
    assert.deepStrictEqual(JSON.parse(text).rules.map(r => [r.id, r.note]), [["a", 1]])
    const plan = plain(Model.savePlan({ text: null }, null, qt([valid("a")])))
    assert.deepStrictEqual([plan.ok, JSON.parse(plan.text).rules.length], [true, 1])
    assert.deepStrictEqual(plain(Model.globalErrors(qt([{ id: null, index: null, code: "using-backup", detail: "invalid-json" }]))),
      [{ key: "error.using-backup", detail: "invalid-json" }])
    // The schema itself takes only an Array, as the Lua decoder does.
    assert.strictEqual(status({ layout: "float", size: { 0: 800, 1: 600, length: 2 } }), "invalid-size")
  },

  "parseDescribe keeps each error's 1-based index and bounds its detail"() {
    const text = JSON.stringify({ loaded: true, api: 1, counters: { opened: 1, matched: 0, moved: 0 }, errors: [
      { id: "a", index: 2, code: "duplicate-id", detail: "rule validation failed: duplicate-id" },
      { id: null, index: null, code: "capability-missing", detail: "missing capability: hl.on" },
      { id: "b", index: 0, code: "resolver-failed" }, { index: -1, code: "x" }, { index: 1.5, code: "x" }, { index: "2", code: "x" },
      { index: 3, code: "handler-failed", detail: "d".repeat(900) }] })
    const errors = plain(Model.parseDescribe(text).errors)
    assert.deepStrictEqual(errors.map(e => e.index), [2, null, null, null, null, null, 3])
    assert.deepStrictEqual(errors[0], { id: "a", index: 2, code: "duplicate-id", detail: "rule validation failed: duplicate-id" })
    assert.deepStrictEqual([errors[2].detail, errors[6].detail.length], ["", 512])
  },

  "listRows matches loader errors to rows by index, then by id"() {
    const list = [valid("x"), valid("x", { name: "Second" }), valid("b"), { id: "Bad!", name: "bad" }]
    const errors = [
      { id: "x", index: 2, code: "duplicate-id", detail: "rule validation failed: duplicate-id" },
      { id: "b", index: 3, code: "resolver-missing", detail: "resolver not registered: gone" },
      { id: null, index: 4, code: "handler-failed", detail: "<b>bold</b>\nnext line" },
      { id: "x", index: null, code: "resolver-failed", detail: "by id" },
      { id: null, index: null, code: "capability-missing", detail: "missing capability: hl.on" }]
    const rows = plain(Model.listRows(list, [], errors))
    // The valid first holder of a duplicated id is not marked; the second
    // row's own status already says what the loader repeats.
    assert.deepStrictEqual(rows.map(r => r.errors.map(e => e.key)),
      [["error.resolver-failed"], ["error.resolver-failed"], ["error.resolver-missing"], ["error.handler-failed"]])
    assert.deepStrictEqual(rows.map(r => r.loaderError), [true, true, true, true])
    assert.strictEqual(rows[1].errorKey, "error.duplicate-id")
    // Markup-shaped detail stays text, on one line.
    assert.deepStrictEqual(rows[3].errors[0], { key: "error.handler-failed", detail: "<b>bold</b> next line" })
    // A list reordered since the save: an index whose row holds another id falls back to the id.
    const moved = plain(Model.listRows([valid("b"), valid("a")], [], [{ id: "a", index: 1, code: "resolver-failed", detail: "" }]))
    assert.deepStrictEqual(moved.map(r => r.errors.length), [0, 1])
    // Out of range with no id: no row.
    assert.deepStrictEqual(plain(Model.listRows([valid("a")], [], [{ id: null, index: 9, code: "x" }]))[0].errors, [])
    assert.deepStrictEqual(plain(Model.globalErrors(errors)), [{ key: "error.capability-missing", detail: "missing capability: hl.on" }])
    assert.deepStrictEqual(plain(Model.globalErrors(null)), [])
  },

  "a loader error's detail is bounded to one display line"() {
    const long = plain(Model.listRows([valid("a")], [], [{ id: "a", index: 1, code: "resolver-failed", detail: "é".repeat(400) }]))[0].errors[0]
    assert.strictEqual(long.detail.length, 160)
    assert.ok(long.detail.endsWith("…"))
    const markup = '<img src="https://example.invalid/t"> &amp;'
    assert.strictEqual(plain(Model.globalErrors([{ id: null, index: null, code: "handler-failed", detail: markup }]))[0].detail, markup)
    assert.strictEqual(plain(Model.globalErrors([{ id: null, index: null, code: "made-up", detail: 5 }]))[0].key, "error.unknown")
    assert.strictEqual(Model.fill(catalog["loader.errorLine"], [catalog["error.handler-failed"], markup]), catalog["error.handler-failed"] + " — " + markup)
  },

  "capability-missing tells a static capability from a dynamic one"() {
    assert.strictEqual(Model.errorKey("capability-missing", "missing capability: o.window"), "error.capability-missing.static")
    for (const detail of ["missing capability: hl.on", "missing capability: o.workspaces.focus", "", undefined, "<b>o.window</b>"])
      assert.strictEqual(Model.errorKey("capability-missing", detail), "error.capability-missing", String(detail))
    assert.strictEqual(Model.errorKey("resolver-failed", "missing capability: o.window"), "error.resolver-failed")
    assert.strictEqual(typeof catalog["error.capability-missing.static"], "string")
    assert.notStrictEqual(catalog["error.capability-missing.static"], catalog["error.capability-missing"])
    // The same static list as the loader's.
    const lua = fs.readFileSync(path.join(pluginDir, "hypr", "window-rules.lua"), "utf8")
    const block = /local STATIC_CAPABILITIES = \{([^}]*)\}/.exec(lua)[1]
    assert.deepStrictEqual(plain(Model.STATIC_CAPABILITIES), [...block.matchAll(/"([^"]+)"/g)].map(m => m[1]))
  },

  "leading RE2 flags become RegExp flags"() {
    const clients = Model.parseClients(JSON.stringify([win({ class: "Steam" }), win({ class: "steam" }), win({ class: "STEAMx" })]))
    for (const p of ["(?i)steam", "(?s).*", "(?m)^a$", "(?is)a.b", "(?ims)x", "(?P<n>a)(?:b)"])
      assert.strictEqual(Model.checkPattern(p, "class"), "", p)
    assert.strictEqual(Model.previewCount({ match: { "class": "(?i)steam", title: "" } }, clients), 2)
    assert.strictEqual(Model.previewCount({ match: { "class": "steam", title: "" } }, clients), 1)
    const lines = [{ class: "a\nb", title: "" }, { class: "a", title: "" }]
    assert.strictEqual(Model.previewCount({ match: { "class": "(?s)a.b", title: "" } }, lines), 1)
    assert.strictEqual(Model.previewCount({ match: { "class": "a.b", title: "" } }, lines), 0)
    // With m, a full match still spans the whole text.
    assert.strictEqual(Model.previewCount({ match: { "class": "(?m)a$", title: "" } }, lines), 1)
    assert.strictEqual(Model.previewCount({ match: { "class": "(?m)a|a\\nb", title: "" } }, lines), 2)
    const rule = valid("a", { match: { "class": "(?i)steam", title: "(?i)game" } })
    assert.deepStrictEqual(plain(Model.checkDraft([valid("a")], 0, rule)), { ok: true, status: "ok", field: "", classError: "", titleError: "", warnings: [] })
  },

  "U and flag groups past the start make a pattern unchecked, not wrong"() {
    for (const p of ["(?U)a+", "(?iU)a", "a(?i)b", "(?i:a)b", "(?-i)a", "(?i)(?s)a", "x|(?U:y)"]) {
      assert.strictEqual(Model.checkPattern(p, "class"), "", p)
      assert.strictEqual(Model.previewCount({ match: { "class": p, title: "" } }, [{ class: "a", title: "" }]), null, p)
      assert.strictEqual(status({ match: { "class": p } }), "ok", p)
    }
    assert.strictEqual(Model.previewCount({ match: { "class": "a", title: "(?U)x" } }, []), null)
    const check = plain(Model.checkDraft([], -1, valid("a", { match: { "class": "(?U)a+", title: "(?U)b" } })))
    assert.deepStrictEqual([check.ok, check.classError, check.warnings], [true, "", ["warn-pattern-unchecked"]])
    // Not a flag group: a class, an escape, a non-capturing group.
    for (const p of ["[(?i)]", "\\(?i\\)", "(?:i)"]) assert.notStrictEqual(Model.previewCount({ match: { "class": p, title: "" } }, []), null, p)
    // A forbidden construct is still refused after leading flags.
    assert.strictEqual(Model.checkPattern("(?i)(?=a)", "class"), "invalid-class")
    assert.strictEqual(typeof catalog["preview.unavailable"], "string")
  },

  "a negative: pattern previews the windows the rest does not match"() {
    const clients = Model.parseClients(JSON.stringify([win({ class: "steam", title: "Game" }), win({ class: "kitty", title: "Game" }),
      win({ class: "firefox", title: "Mail" })]))
    const count = (cls, title = "") => Model.previewCount({ match: { "class": cls, title } }, clients)
    assert.strictEqual(count("negative:steam"), 2)
    assert.strictEqual(count("negative:(?i)STEAM"), 2)
    assert.strictEqual(count(".*", "negative:Game"), 1)
    assert.strictEqual(count("negative:steam", "Game"), 1)
    assert.strictEqual(Model.checkPattern("negative:steam", "class"), "")
    assert.strictEqual(Model.checkPattern("negative:(?=a)", "class"), "invalid-class")
    const check = plain(Model.checkDraft([], -1, valid("a", { match: { "class": "negative:steam", title: "" } })))
    assert.deepStrictEqual([check.ok, check.warnings], [true, ["warn-pattern-negative"]])
    const both = plain(Model.checkDraft([], -1, valid("a", { layout: "tile", size: [1, 1], match: { "class": "negative:a", title: "(?U)b" } })))
    assert.deepStrictEqual(both.warnings, ["warn-geometry-not-floating", "warn-pattern-negative", "warn-pattern-unchecked"])
  },

  "the preview is bounded"() {
    const long = "x".repeat(600)
    // Class and title are tested on their first 512 units.
    assert.strictEqual(Model.previewCount({ match: { "class": "x{512}", title: "" } }, [{ class: long, title: "" }]), 1)
    assert.strictEqual(Model.previewCount({ match: { "class": ".*", title: "x{512}" } }, [{ class: "a", title: long }]), 1)
    assert.strictEqual(Model.previewCount({ match: { "class": "a.*", title: "" } }, qt(Array.from({ length: 600 }, () => ({ class: "ab", title: "" })))), 512)
    // A pattern over 256 characters is refused before anything compiles.
    assert.strictEqual(Model.checkPattern("a".repeat(257), "class"), "invalid-class")
    assert.strictEqual(Model.previewCount({ match: { "class": "a".repeat(257), title: "" } }, [{ class: "a", title: "" }]), 0)
  },

  "a compile error stops a save only when the draft changed that pattern"() {
    const handWritten = valid("a", { match: { "class": "(", title: "[" } })
    const list = [handWritten, valid("b")]
    const kept = plain(Model.checkDraft(list, 0, { ...handWritten, name: "Renamed" }, handWritten))
    assert.deepStrictEqual([kept.ok, kept.classError, kept.titleError], [true, "pattern-syntax", "pattern-syntax"])
    const edited = plain(Model.checkDraft(list, 0, { ...handWritten, match: { "class": "((", title: "[" } }, handWritten))
    assert.deepStrictEqual([edited.ok, edited.classError], [false, "pattern-syntax"])
    const title = plain(Model.checkDraft(list, 0, { ...handWritten, match: { "class": "(", title: "[[" } }, handWritten))
    assert.strictEqual(title.ok, false)
    // A schema error blocks whatever the original was.
    const shape = valid("a", { match: { "class": "(?=a)" } })
    assert.strictEqual(plain(Model.checkDraft([shape], 0, shape, shape)).ok, false)
    // A new rule has no original.
    assert.strictEqual(plain(Model.checkDraft(list, -1, valid("c", { match: { "class": "(" } }))).ok, false)
  },

  "repairRule keeps what is valid and resets what is not"() {
    const raw = { id: "Bad!", name: "Kept name", custom: [1], layout: "sideways", size: [0, 1], follow: "yes",
      match: { "class": "^a$", title: "(?=x)", extra: 1 }, fullscreen: true, maximize: true, opacity: 0.5 }
    const before = JSON.stringify(raw)
    const repaired = plain(Model.repairRule(raw, ["kept-name"]))
    assert.strictEqual(JSON.stringify(raw), before)
    assert.deepStrictEqual(repaired.fieldErrors, [
      { field: "id", code: "invalid-id" }, { field: "title", code: "invalid-title" }, { field: "flags", code: "invalid-flag" },
      { field: "layout", code: "invalid-layout" }, { field: "size", code: "invalid-size" }, { field: "flags", code: "conflicting-effects" }])
    assert.deepStrictEqual(repaired.rule, { id: "kept-name-2", name: "Kept name", enabled: true,
      match: { mode: "regex", "class": "^a$", title: "", titleMode: "regex", initial: false, extra: 1 },
      workspace: { type: "none" }, follow: true, layout: "default", size: null, position: { type: "none" }, monitor: null,
      fullscreen: true, maximize: false, pin: false, opacity: 0.5, noInitialFocus: false, custom: [1] })
    assert.strictEqual(status(repaired.rule), "ok")
    // Missing optional fields are filled, not reported.
    const sparse = plain(Model.repairRule({ id: "a", name: "A", match: { "class": "^a$" } }, []))
    assert.deepStrictEqual(sparse.fieldErrors, [])
    assert.deepStrictEqual(sparse.rule, plain(Model.validateDocument(doc([{ id: "a", name: "A", match: { "class": "^a$" } }])).rules[0].rule))
  },

  "repairRule frees a taken id and makes any entry editable"() {
    const dup = plain(Model.repairRule(valid("x"), qt(["x", "y"])))
    assert.deepStrictEqual([dup.rule.id, dup.fieldErrors], ["x-2", [{ field: "id", code: "duplicate-id" }]])
    const odd = plain(Model.repairRule("not a rule", []))
    assert.deepStrictEqual(odd.fieldErrors, [{ field: "rule", code: "invalid-rule" }, { field: "class", code: "invalid-class" }])
    assert.deepStrictEqual([odd.rule.id, odd.rule.name, odd.rule.match.class], ["rule", "rule", ""])
    const nameless = plain(Model.repairRule({ id: "a", name: "\u0007", match: { "class": "^a$" } }, []))
    assert.deepStrictEqual([nameless.rule.name, nameless.fieldErrors], ["a", [{ field: "name", code: "invalid-name" }]])
    const markup = plain(Model.repairRule({ id: "a", name: "<b>x</b>", match: { "class": "^<i>$" }, layout: 3 }, []))
    assert.deepStrictEqual([markup.rule.name, markup.rule.match.class], ["<b>x</b>", "^<i>$"])
    // Saved in place of the invalid entry, the file is valid again.
    const text = JSON.stringify({ version: 1, revision: 2, rules: [valid("a"), { id: "a", name: "Copy", match: { "class": "^b$" }, layout: "x" }] })
    const rules = plain(Model.documentRules(Model.parseDocument(text)))
    const fixed = plain(Model.repairRule(rules[1], Model.ruleIds(rules, 1)))
    const plan = plain(Model.savePlan({ revision: 2, text }, text, Model.putRule(rules, 1, fixed.rule)))
    assert.strictEqual(plan.ok, true)
    assert.deepStrictEqual(plain(Model.parseDocument(plan.text).validation.rules.map(r => r.status)), ["ok", "ok"])
    assert.deepStrictEqual(JSON.parse(plan.text).rules.map(r => r.id), ["a", "a-2"])
    for (const item of [...fixed.fieldErrors, ...dup.fieldErrors, ...odd.fieldErrors])
      assert.strictEqual(typeof catalog[Model.errorKey(item.code)], "string", item.code)
    assert.ok(catalog["editor.repairedField"].includes("%1"))
  },

  "editor limits and the list limit come from Model.js"() {
    for (const name of ["MIN_WORKSPACE_ID", "MAX_WORKSPACE_ID", "MIN_SLOT", "MAX_SLOT", "MIN_ARG", "MAX_ARG", "MIN_SIZE", "MIN_POSITION",
      "MAX_GEOMETRY", "MIN_OPACITY", "MAX_OPACITY", "MAX_RULES"])
      assert.strictEqual(typeof Model[name], "number", name)
    assert.ok(catalog["error.invalid-size"].includes(String(Model.MAX_GEOMETRY)))
    assert.ok(catalog["error.invalid-opacity"].includes(Math.round(Model.MIN_OPACITY * 100) + "%"))
    assert.ok(catalog["list.full"].includes("%1"))
    assert.strictEqual(Model.fill(catalog["list.full"], [Model.MAX_RULES]).includes("200"), true)
    for (const code of Model.EDITOR_CODES) assert.strictEqual(typeof catalog["error." + code], "string", code)
  },

  "README contains LOAD_BLOCK verbatim, examples/hyprland.lua contains its lines, and every diagnostic code is documented"() {
    const readme = fs.readFileSync(path.join(pluginDir, "README.md"), "utf8")
    const example = fs.readFileSync(path.join(pluginDir, "examples", "hyprland.lua"), "utf8")

    assert.ok(readme.includes("```lua\n" + Model.LOAD_BLOCK + "\n```"),
      "README.md must contain Model.LOAD_BLOCK verbatim in a lua code block")

    const exampleLines = example.split(/\r?\n/).map(line => line.trim())
    const requiredLines = Model.LOAD_BLOCK.split("\n")
      .map(line => line.trim())
      .filter(line => !line.startsWith("--"))
    let cursor = 0
    for (const line of requiredLines) {
      const found = exampleLines.indexOf(line, cursor)
      assert.ok(found >= 0, `examples/hyprland.lua is missing load block line: ${line}`)
      cursor = found + 1
    }

    const documentedCodes = [...Model.FILE_CODES, ...Model.RULE_CODES, ...Model.LOADER_CODES,
      ...Model.EDITOR_CODES, ...Model.WARNING_CODES]
    for (const code of documentedCodes) {
      assert.ok(readme.includes("`" + code + "`"), `README.md is missing diagnostic code: ${code}`)
    }
  }
})

// ---------- Exact-app matching (README, "How a match compiles") ----------

const apps = (classes, over = {}) => ({ mode: "apps", classes, title: "", titleMode: "exact", initial: false, ...over })

Object.assign(tests, {
  "compileMatch is what Hyprland is given, and its patterns match what the preview matches"() {
    assert.deepStrictEqual(plain(Model.compileMatch(apps(qt(["a.b", "c"])))), { "class": "^(a\\.b|c)$" })
    assert.deepStrictEqual(plain(Model.compileMatch(apps(["😀 x"], { title: "a/b", initial: true }))),
      { initial_class: "^(😀\\ x)$", initial_title: "^a\\/b$" })
    assert.deepStrictEqual(plain(Model.compileMatch({ mode: "regex", "class": "^a$", title: "", titleMode: "regex", initial: true })),
      { initial_class: "^a$" })
    // Every printable ASCII character that is not a word character is escaped, and the result is a literal.
    const ascii = Array.from({ length: 95 }, (_, i) => String.fromCharCode(32 + i)).join("")
    const compiled = Model.compileMatch(apps([ascii])).class
    assert.match(ascii, new RegExp(compiled))
    assert.ok(!new RegExp(compiled).test(ascii + "x"))
    assert.strictEqual(Model.checkPattern(compiled, "class"), "")
    for (const c of ascii) assert.strictEqual(compiled.includes("\\" + c), !/[A-Za-z0-9_]/.test(c), c)
  },

  "normalization keeps only the class key of the match mode"() {
    const appsRule = validate([base({ match: { mode: "apps", classes: ["a"], "class": "^stale$", hint: 1 } })]).rules[0]
    assert.strictEqual(appsRule.status, "ok")
    assert.deepStrictEqual(appsRule.rule.match, { mode: "apps", classes: ["a"], title: "", titleMode: "regex", initial: false, hint: 1 })
    const regexRule = validate([base({ match: { mode: "regex", "class": "^a$", classes: ["stale"] } })]).rules[0]
    assert.deepStrictEqual(regexRule.rule.match, { mode: "regex", "class": "^a$", title: "", titleMode: "regex", initial: false })
    // The schema itself takes only an Array, as the Lua decoder does.
    assert.strictEqual(status({ match: { mode: "apps", classes: { 0: "a", length: 1 } } }), "invalid-class")
    assert.strictEqual(status({ match: { mode: "apps", classes: ["a"], title: "x\u0007", titleMode: "exact" } }), "invalid-title")
    assert.strictEqual(status({ match: { mode: "apps", classes: ["a"], title: "é".repeat(257), titleMode: "exact" } }), "invalid-title")
    assert.strictEqual(status({ match: { mode: "apps", classes: ["a"], titleMode: null } }), "invalid-title")
    assert.strictEqual(status({ match: { mode: null, "class": "^a$" } }), "invalid-class")
    assert.strictEqual(status({ match: { mode: "apps", classes: ["a"], initial: null } }), "invalid-flag")
    // The class check comes before the title, the title before initial.
    assert.strictEqual(status({ match: { mode: "apps", classes: [], title: 5, initial: 1 } }), "invalid-class")
    assert.strictEqual(status({ match: { mode: "apps", classes: ["a"], title: 5, initial: 1 } }), "invalid-title")
  },

  "serialize and normalize round trip keeps the fields of each mode and unknown match keys"() {
    const original = { version: 1, revision: 2, rules: [
      base({ id: "a", match: { mode: "apps", classes: ["Code", "T3 Code"], title: "Main", titleMode: "exact", initial: true, hint: "kept" } }),
      base({ id: "b", match: { "class": "^b$", note: 1 } })] }
    const parsed = Model.parseDocument(JSON.stringify(original))
    const rules = plain(Model.documentRules(parsed))
    assert.deepStrictEqual(rules[1].match, { mode: "regex", "class": "^b$", title: "", titleMode: "regex", initial: false, note: 1 })
    // The editor rebuilt "a" without its unknown key and switched "b" to apps.
    const edited = [base({ id: "a", match: apps(["Code"]) }), { ...rules[1], match: Model.switchMatchMode(rules[1].match, "apps", { classes: ["b"] }).match }]
    const written = JSON.parse(Model.serializeDocument(parsed.doc, edited, 3))
    assert.deepStrictEqual(written.rules[0].match, { mode: "apps", classes: ["Code"], title: "", titleMode: "exact", initial: false, hint: "kept" })
    assert.deepStrictEqual(Object.keys(written.rules[1].match), ["mode", "classes", "title", "titleMode", "initial", "note"])
    assert.deepStrictEqual(written.rules[1].match.classes, ["b"])
    const again = plain(Model.parseDocument(JSON.stringify(written)))
    assert.deepStrictEqual(again.validation.rules.map(r => r.status), ["ok", "ok"])
    assert.deepStrictEqual(plain(Model.documentRules(again)).map(r => r.match), written.rules.map(r => r.match))
  },

  "capture and the picker produce apps-mode rules"() {
    const clients = Model.parseClients(JSON.stringify([win({ class: "com.t3tools.T3Code", initialClass: "t3code", initialTitle: "T3 Code" })]))
    assert.deepStrictEqual(plain([clients[0].initialClass, clients[0].initialTitle]), ["t3code", "T3 Code"])
    assert.strictEqual(Model.parseActiveWindow(JSON.stringify(win({ initialClass: "x".repeat(600) }))).initialClass.length, 512)
    const picked = plain(Model.ruleFromWindow({ ...clients[0], at: qt(clients[0].at), size: qt(clients[0].size) }, qt(MONITORS), qt([])))
    assert.deepStrictEqual(picked.rule.match, apps(["com.t3tools.T3Code"]))
    assert.strictEqual(picked.title, "notes.txt - Editor")
    assert.strictEqual(status(picked.rule), "ok")
    const active = plain(Model.ruleFromWindow(Model.parseActiveWindow(JSON.stringify(win())), MONITORS, []))
    assert.deepStrictEqual(active.rule.match, apps(["org.example.Editor"]))
    // A client with no class gives an empty list, which the editor asks to fill.
    assert.deepStrictEqual(plain(Model.ruleFromWindow({ title: "t" }, [], [])).rule.match.classes, [])
  },

  "newRule starts in apps mode and needs an app before it can be saved"() {
    const rule = plain(Model.newRule("Editors", []))
    assert.deepStrictEqual(rule.match, apps([]))
    const empty = plain(Model.checkDraft([], -1, rule))
    assert.deepStrictEqual([empty.ok, empty.status, empty.field, empty.classError], [false, "invalid-class", "class", "invalid-class"])
    assert.strictEqual(Model.matchErrorKey(empty.status, rule.match), "error.invalid-apps")
    assert.strictEqual(Model.matchErrorKey("invalid-class", { "class": "(" }), "error.invalid-class")
    assert.strictEqual(Model.matchErrorKey("invalid-title", rule.match), "error.invalid-title")
    const chosen = plain(Model.checkDraft([], -1, { ...rule, match: apps(["org.example.Editor"]) }))
    assert.deepStrictEqual([chosen.ok, chosen.status], [true, "ok"])
  },

  "exact values never get pattern errors or warnings"() {
    for (const value of ["(", "(?=x)", "(?U)a", "negative:a", "a\\1"]) {
      const check = plain(Model.checkDraft([], -1, valid("a", { match: apps([value], { title: value }) })))
      assert.deepStrictEqual([check.ok, check.classError, check.titleError, check.warnings], [true, "", "", []], value)
      assert.strictEqual(Model.previewCount({ match: apps([value], { title: value }) }, [{ class: value, title: value }]), 1, value)
    }
    const regexTitle = plain(Model.checkDraft([], -1, valid("a", { match: apps(["a"], { title: "(", titleMode: "regex" }) })))
    assert.deepStrictEqual([regexTitle.ok, regexTitle.titleError], [false, "pattern-syntax"])
    const badExact = plain(Model.checkDraft([], -1, valid("a", { match: apps(["a"], { title: "a\u0007" }) })))
    assert.deepStrictEqual([badExact.ok, badExact.status, badExact.field, badExact.titleError], [false, "invalid-title", "title", "invalid-title"])
  },

  "the preview matches apps exactly, exact titles by equality and initial values when asked"() {
    const clients = Model.parseClients(JSON.stringify([
      win({ class: "Code", title: "a.txt", initialClass: "code-oss", initialTitle: "Welcome" }),
      win({ class: "T3 Code", title: "Main", initialClass: "t3", initialTitle: "Main" }),
      win({ class: "Codex", title: "a.txt", initialClass: "Code", initialTitle: "Welcome" })]))
    const count = match => Model.previewCount({ match }, clients)
    assert.strictEqual(count(apps(["Code"])), 1)
    assert.strictEqual(count(apps(["Code", "T3 Code"])), 2)
    assert.strictEqual(count(apps(["code"])), 0)
    assert.strictEqual(count(apps(["Code", "Codex"], { title: "a.txt" })), 2)
    assert.strictEqual(count(apps(["Code", "Codex"], { title: "a.tx" })), 0)
    assert.strictEqual(count(apps(["Code", "Codex"], { title: "a.*", titleMode: "regex" })), 2)
    assert.strictEqual(count(apps(["Code"], { initial: true })), 1)
    assert.strictEqual(count(apps(["Code"], { title: "Welcome", initial: true })), 1)
    assert.strictEqual(count(apps(["Code"], { title: "a.txt", initial: true })), 0)
    assert.strictEqual(count({ mode: "regex", "class": "Code.*", title: "", titleMode: "regex", initial: true }), 1)
    assert.strictEqual(count({ mode: "regex", "class": "Code.*", title: "a.txt", titleMode: "exact" }), 2)
    // A list from QML, and lists the schema refuses.
    assert.strictEqual(Model.previewCount({ match: apps(qt(["Code", "T3 Code"])) }, qt(clients)), 2)
    assert.strictEqual(count(apps([])), 0)
    assert.strictEqual(count(apps([5])), 0)
    assert.strictEqual(count({ mode: "glob", "class": "Code" }), 0)
    assert.strictEqual(count(apps(["Code"], { titleMode: "glob", title: "x" })), 0)
    // A class named like an Object property is only a class.
    assert.strictEqual(Model.previewCount({ match: apps(["__proto__"]) }, [{ class: "toString", title: "" }, { class: "__proto__", title: "" }]), 1)
  },

  "the editor helpers accept classes as a Qt list"() {
    const draft = valid("a", { match: apps(qt(["Code", "T3 Code"])) })
    const check = plain(Model.checkDraft(qt([valid("a")]), 0, draft))
    assert.deepStrictEqual([check.ok, check.classError], [true, ""])
    const put = plain(Model.putRule([valid("a")], 0, draft))
    assert.deepStrictEqual(put[0].match.classes, ["Code", "T3 Code"])
    assert.ok(Array.isArray(Model.draftRule(draft).match.classes))
    // draftRule copies; the draft as given is left alone.
    assert.ok(!Array.isArray(draft.match.classes))
    const plan = plain(Model.savePlan({ text: null }, null, [Model.draftRule(draft)]))
    assert.deepStrictEqual(JSON.parse(plan.text).rules[0].match.classes, ["Code", "T3 Code"])
    assert.deepStrictEqual(plain(Model.uniqueClasses(qt(["b", "a", "b", "", 5, "c\u0007"]), qt(["a", "d"]))), ["b", "a", "d"])
    assert.strictEqual(Model.uniqueClasses(Array.from({ length: 40 }, (_, i) => "c" + i)).length, 32)
    assert.deepStrictEqual(plain(Model.switchMatchMode({ ...draft.match }, "regex", {})).match,
      { mode: "regex", "class": "^(Code|T3\\ Code)$", title: "", titleMode: "exact", initial: false })
    const rows = plain(Model.listRows(qt([draft]), [], []))
    assert.deepStrictEqual([rows[0].matchMode, rows[0].matchLabel], ["apps", "Code, T3 Code"])
  },

  "switchMatchMode keeps what the other mode had"() {
    const start = apps(["Code", "T3 Code"], { title: "x", hint: 1 })
    const toRegex = plain(Model.switchMatchMode(start, "regex", null))
    assert.deepStrictEqual(toRegex.match, { mode: "regex", "class": "^(Code|T3\\ Code)$", title: "x", titleMode: "exact", initial: false, hint: 1 })
    assert.deepStrictEqual(toRegex.stash, { classes: ["Code", "T3 Code"] })
    const edited = { ...toRegex.match, "class": "Code.*" }
    const back = plain(Model.switchMatchMode(edited, "apps", toRegex.stash))
    assert.deepStrictEqual(back.match, { ...start })
    assert.deepStrictEqual(back.stash, { classes: ["Code", "T3 Code"], pattern: "Code.*" })
    // The stashed pattern comes back too, and the input is not changed.
    const before = JSON.stringify(back.match)
    assert.strictEqual(plain(Model.switchMatchMode(back.match, "regex", back.stash)).match.class, "Code.*")
    assert.strictEqual(JSON.stringify(back.match), before)
    // No classes and nothing stashed: an empty pattern, and an empty list.
    assert.strictEqual(plain(Model.switchMatchMode(apps([]), "regex", {})).match.class, "")
    assert.deepStrictEqual(plain(Model.switchMatchMode({ "class": "^a$" }, "apps", {})).match, { mode: "apps", classes: [] })
    // Same or unknown mode: unchanged.
    assert.deepStrictEqual(plain(Model.switchMatchMode(start, "apps", {})).match, start)
    assert.deepStrictEqual(plain(Model.switchMatchMode(start, "glob", {})).match, start)
  },

  "titleSuggestion turns an exact title into the regex that matches it"() {
    assert.strictEqual(Model.titleSuggestion("a.txt - Editor", "exact", "exact"), "a.txt - Editor")
    assert.strictEqual(Model.titleSuggestion("a.txt - Editor", "exact", "regex"), "^a\\.txt\\ \\-\\ Editor$")
    assert.strictEqual(Model.previewCount({ match: { "class": ".*", title: Model.titleSuggestion("a.txt (1)", "exact", "regex") } },
      [{ class: "x", title: "a.txt (1)" }, { class: "x", title: "aXtxt (1)" }]), 1)
    assert.strictEqual(Model.titleSuggestion(".*Steam.*", "regex", "regex"), ".*Steam.*")
    assert.strictEqual(Model.titleSuggestion(".*Steam.*", "regex", "exact"), "")
    assert.strictEqual(Model.titleSuggestion("", "exact", "regex"), "")
    assert.strictEqual(Model.titleSuggestion(null, "exact", "exact"), "")
  },

  "classOptions lists each open window's class once, then the rule's own"() {
    const clients = Model.parseClients(JSON.stringify([win({ class: "Code", title: "<b>a</b>\nb" }), win({ class: "Code", title: "other" }),
      win({ class: "kitty", title: "" })]))
    assert.deepStrictEqual(plain(Model.classOptions(qt(clients), qt(["Gone", "Code", ""]))), [
      { value: "Code", label: "Code", description: "<b>a</b> b" },
      { value: "kitty", label: "kitty", description: "" },
      { value: "Gone", label: "Gone", description: "" }])
    assert.deepStrictEqual(plain(Model.classOptions(null, null)), [])
    assert.deepStrictEqual(plain(Model.classOptions([{ class: "x".repeat(257), title: "" }], [])), [])
  },

  "typedClass trims and refuses what cannot be a class"() {
    assert.strictEqual(Model.typedClass("  org.example.App  "), "org.example.App")
    for (const text of ["", "   ", "a\u0007", "x".repeat(257), null, 5]) assert.strictEqual(Model.typedClass(text), "", String(text))
    assert.strictEqual(Model.typedClass("😀".repeat(256)), "😀".repeat(256))
  },

  "listRows shows the app list or the pattern, on one bounded line"() {
    const rows = plain(Model.listRows([
      valid("a", { match: apps(["Code", "<b>T3</b>"]) }),
      valid("b", { match: { "class": "^(steam|steam_app_.+)$" } }),
      valid("c", { match: apps(Array.from({ length: 32 }, (_, i) => "com.example.Application" + i)) }),
      { id: "d", name: "D", match: { mode: "apps", classes: ["ok", 5, "a\nb"] } },
      { id: "e", name: "E", match: "x" }], [], []))
    assert.deepStrictEqual(rows.map(r => r.matchMode), ["apps", "regex", "apps", "apps", "regex"])
    assert.deepStrictEqual([rows[0].matchLabel, rows[1].matchLabel], ["Code, <b>T3</b>", "^(steam|steam_app_.+)$"])
    assert.strictEqual(rows[2].matchLabel.length, 160)
    assert.ok(rows[2].matchLabel.startsWith("com.example.Application0, com.example.Application1, "))
    assert.ok(rows[2].matchLabel.endsWith("…"))
    assert.deepStrictEqual([rows[3].matchLabel, rows[4].matchLabel], ["ok, a b", ""])
  },

  "repairRule handles the match fields of both modes"() {
    const fieldsOf = r => r.fieldErrors.map(e => e.code)
    const partial = plain(Model.repairRule({ id: "a", name: "A", match: { mode: "apps", classes: ["Code", 5, "Code", "x\u0007", "T3"],
      title: "(", titleMode: "exact", initial: "yes", hint: 1 } }, []))
    assert.deepStrictEqual(partial.rule.match, { mode: "apps", classes: ["Code", "T3"], title: "(", titleMode: "exact", initial: false, hint: 1 })
    assert.deepStrictEqual(fieldsOf(partial), ["invalid-class", "invalid-flag"])
    assert.strictEqual(status(partial.rule), "ok")
    const unknown = plain(Model.repairRule({ id: "a", name: "A", match: { mode: "glob", "class": "x", title: "t", titleMode: "glob" } }, []))
    assert.deepStrictEqual(unknown.rule.match, apps([]))
    assert.deepStrictEqual(fieldsOf(unknown), ["invalid-class", "invalid-title"])
    const regex = plain(Model.repairRule({ id: "a", name: "A", match: { mode: "regex", "class": "(?=a)", classes: ["stale"], title: "(?=t)" } }, []))
    assert.deepStrictEqual(regex.rule.match, { mode: "regex", "class": "", title: "", titleMode: "regex", initial: false })
    const kept = plain(Model.repairRule({ id: "a", name: "A", layout: "x", match: apps(["Code"], { title: "T", initial: true }) }, []))
    assert.deepStrictEqual([kept.rule.match, fieldsOf(kept)], [apps(["Code"], { title: "T", initial: true }), ["invalid-layout"]])
    assert.deepStrictEqual(kept.rule, plain(Model.validateDocument(doc([kept.rule])).rules[0].rule))
  },

  "every match label and error of the editor has its text in en.json"() {
    for (const key of ["field.matchBy", "option.match.apps", "option.match.regex", "field.apps.placeholder",
      "field.apps.empty", "field.apps.none", "field.apps.add", "field.apps.addPlaceholder", "field.titleMatch", "option.title.off",
      "option.title.exact", "option.title.regex", "field.title.exact", "toggle.initial", "toggle.initial.hint", "error.invalid-apps",
      "action.addApp", "field.apps.full"])
      assert.strictEqual(typeof catalog[key], "string", key)
    assert.match(catalog["error.invalid-class"], /apps?/)
    assert.match(catalog["error.invalid-apps"], /32/)
    // Every key the QML names literally.
    for (const file of fs.readdirSync(pluginDir).filter(name => name.endsWith(".qml"))) {
      const qml = fs.readFileSync(path.join(pluginDir, file), "utf8")
      for (const [, key] of qml.matchAll(/\btn?\("([^"]+)"\s*[,)]/g)) assert.ok(key in catalog, file + ": " + key)
    }
  }
})


// ---------- Panel decisions: lists, confirmations, conflicts and captures ----------

Object.assign(tests, {
  "an array-like list longer than MAX_LIST_LIKE, or with a broken length, is not a list"() {
    assert.strictEqual(Model.MAX_LIST_LIKE, 4096)
    assert.strictEqual(Model.arrayLike({ length: 4096 }).length, 4096)
    for (const value of [{ length: 4097 }, { length: 1e9 }, { length: 1.5 }, { length: -1 }, { length: "3" }, { length: Infinity }]) {
      assert.strictEqual(Model.isArrayLike(value), false, JSON.stringify(value))
      assert.deepStrictEqual(plain(Model.arrayLike(value)), [])
    }
    // A real Array is read as it is, whatever its length.
    assert.strictEqual(Model.arrayLike(new Array(5000).fill("x")).length, 5000)
  },

  "a forged length in classes, rules or clients returns at once with no items"() {
    const huge = { length: 1e9 }
    const started = Date.now()
    const forged = { id: "a", name: "A", match: { mode: "apps", classes: huge } }
    const rows = plain(Model.listRows([forged], [], []))
    assert.strictEqual(rows.length, 1)
    assert.strictEqual(rows[0].valid, false)
    assert.strictEqual(rows[0].matchLabel, "")
    assert.deepStrictEqual(plain(Model.compileMatch(forged.match)), { "class": "^()$" })
    assert.deepStrictEqual(plain(Model.uniqueClasses(huge, huge)), [])
    assert.deepStrictEqual(plain(Model.classOptions(huge, huge)), [])
    assert.deepStrictEqual(plain(Model.repairRule(forged, []).rule.match.classes), [])
    assert.strictEqual(Model.previewCount(forged, [win()]), 0)
    assert.deepStrictEqual(plain(Model.listRows(huge, huge, huge)), [])
    assert.deepStrictEqual(plain(Model.ruleIds(huge, -1)), [])
    assert.deepStrictEqual(plain(Model.removeRule(huge, 0)), [])
    assert.strictEqual(Model.previewCount(base({ match: apps(["org.example.Editor"]) }), huge), 0)
    assert.deepStrictEqual(plain(Model.classOptions(huge, ["Code"])).map(o => o.value), ["Code"])
    assert.ok(Date.now() - started < 1000, "took " + (Date.now() - started) + " ms")
  },

  "a confirmation acts on the entry it was asked about, wherever it went"() {
    const a = base({ id: "a", name: "Alpha" }), b = base({ id: "b", name: "Beta" }), c = base({ id: "c", name: "Gamma" })
    const asked = plain(Model.entryIdentity([a, b, c], 1))
    assert.deepStrictEqual([asked.index, asked.id, asked.name], [1, "b", "Beta"])
    assert.strictEqual(Model.findEntry([a, b, c], asked), 1)
    // Another bar reordered the list: the entry moved, and index 1 now holds another rule.
    assert.strictEqual(Model.findEntry([b, a, c], asked), 0)
    assert.strictEqual(Model.findEntry([a, c, b], asked), 2)
    // Changed or removed: there is nothing to act on.
    assert.strictEqual(Model.findEntry([a, { ...b, name: "Beta 2" }, c], asked), -1)
    assert.strictEqual(Model.findEntry([a, c], asked), -1)
    assert.strictEqual(Model.findEntry([], asked), -1)
    assert.strictEqual(Model.entryIdentity([a], 1), null)
    assert.strictEqual(Model.entryIdentity([a], -1), null)
    assert.strictEqual(Model.findEntry([a], null), -1)
  },

  "a confirmation tells apart invalid entries and entries that share an id"() {
    const first = { id: "x", name: "First", match: { "class": 5 } }
    const second = { id: "x", name: "Second", match: { "class": "^x$" } }
    const junk = [1, 2]
    const asked = plain(Model.entryIdentity([first, second, junk], 1))
    assert.strictEqual(asked.name, "Second")
    assert.strictEqual(Model.findEntry([second, first, junk], asked), 0)
    assert.strictEqual(Model.findEntry([first, junk], asked), -1)
    const askedJunk = plain(Model.entryIdentity([first, second, junk], 2))
    assert.deepStrictEqual([askedJunk.id, askedJunk.name], ["", ""])
    assert.strictEqual(Model.findEntry([junk, first, second], askedJunk), 0)
    assert.strictEqual(Model.findEntry([first, second, [1, 3]], askedJunk), -1)
    // Key order does not make an entry another one.
    assert.strictEqual(Model.findEntry([{ name: "Second", match: { "class": "^x$" }, id: "x" }], asked), 0)
    // Two identical entries: the one nearest to where it was asked.
    const twins = [a0(), base({ id: "t" }), a0(), base({ id: "t" })]
    const askedTwin = plain(Model.entryIdentity(twins, 3))
    assert.strictEqual(Model.findEntry([base({ id: "t" }), a0(), a0(), base({ id: "t" })], askedTwin), 3)
    assert.strictEqual(Model.findEntry([base({ id: "t" }), a0(), a0(), a0()], askedTwin), 0)
    // The name shown comes from a file: one plain line.
    assert.strictEqual(plain(Model.entryIdentity([{ id: "m", name: "<b>x</b>\nnext" }], 0)).name, "<b>x</b> next")
    function a0() { return base({ id: "a0" }) }
  },

  "reapplying a kept rule onto a full file is refused before anything is cleared"() {
    const full = Array.from({ length: Model.MAX_RULES }, (_, i) => base({ id: "r" + i }))
    const fresh = base({ id: "new-rule", name: "New" })
    assert.deepStrictEqual(plain(Model.reapplyPlan(full, { rule: fresh, original: null })),
      { ok: false, reason: "save.tooManyRules", detail: String(Model.MAX_RULES) })
    // In place of the original it still fits.
    const plan = plain(Model.reapplyPlan(full, { rule: { ...full[3], name: "Edited" }, original: full[3] }))
    assert.deepStrictEqual([plan.ok, plan.index, plan.rule.name], [true, 3, "Edited"])
    const roomy = plain(Model.reapplyPlan(full.slice(1), { rule: fresh, original: null }))
    assert.deepStrictEqual([roomy.ok, roomy.index, roomy.rule.id], [true, -1, "new-rule"])
    assert.strictEqual(Model.reapplyPlan(full, null).ok, false)
  },

  "adding a 33rd app is refused, not dropped"() {
    const many = Array.from({ length: Model.MAX_CLASSES }, (_, i) => "app" + i)
    assert.deepStrictEqual(plain(Model.addClass(many, "extra")), { classes: many, refused: true })
    assert.deepStrictEqual(plain(Model.addClass(many, "app3")), { classes: many, refused: false })
    assert.deepStrictEqual(plain(Model.addClass(["a"], "b")), { classes: ["a", "b"], refused: false })
    assert.deepStrictEqual(plain(Model.addClass(["a"], "")), { classes: ["a"], refused: false })
    assert.match(Model.fill(catalog["field.apps.full"], [Model.MAX_CLASSES]), /32/)
  },

  "a capture opens only where the editor can show it"() {
    for (const mode of ["list", "editor", "setup"]) assert.strictEqual(Model.captureBlocker(mode, false), "", mode)
    assert.strictEqual(Model.captureBlocker("conflict", false), "capture.conflict")
    assert.strictEqual(Model.captureBlocker("invalid", false), "save.notEditable")
    assert.strictEqual(Model.captureBlocker("unsupported", false), "save.notEditable")
    assert.strictEqual(Model.captureBlocker("loading", false), "state.loading")
    assert.strictEqual(Model.captureBlocker("list", true), "save.busy")
    for (const mode of ["conflict", "invalid", "unsupported", "loading"])
      assert.strictEqual(typeof catalog[Model.captureBlocker(mode, false)], "string", mode)
  },

  "the capture's monitor is the focused display"() {
    const monitors = plain(Model.parseMonitors(JSON.stringify([{ ...MONITORS[0], focused: false }, { ...MONITORS[1], focused: true }])))
    assert.deepStrictEqual(monitors.map(m => m.focused), [false, true])
    assert.strictEqual(plain(Model.parseMonitors(JSON.stringify([{ ...MONITORS[0], focused: "yes" }])))[0].focused, false)
    assert.strictEqual(Model.focusedMonitorName(monitors, win({ monitor: 0 })), "DP-2")
    const unfocused = monitors.map(m => ({ ...m, focused: false }))
    assert.strictEqual(Model.focusedMonitorName(unfocused, win({ monitor: 0 })), "eDP-1")
    assert.strictEqual(Model.focusedMonitorName(unfocused, null), "")
    assert.strictEqual(Model.focusedMonitorName([], win()), "")
  },

  "loaderNotes names an older rules format and a newer loader API"() {
    const loader = { loaded: true, loaderVersion: "1.0.0", revision: 8, schema: 1, api: 1 }
    assert.deepStrictEqual(plain(Model.loaderNotes(loader, 8, "1.0.0")), [])
    assert.deepStrictEqual(plain(Model.loaderNotes({ ...loader, schema: 0, api: 2 }, 8, "1.0.0")), [
      { key: "loader.schemaOlder", args: ["0", String(Model.SCHEMA_VERSION)] },
      { key: "loader.apiNewer", args: ["2", String(Model.LOADER_API)] }])
    assert.deepStrictEqual(plain(Model.loaderNotes({ ...loader, schema: 2, api: 0 }, 8, "1.0.0")), [])
    for (const key of ["loader.schemaOlder", "loader.apiNewer"]) assert.strictEqual(typeof catalog[key], "string", key)
    // As parseDescribe reads them.
    const described = plain(Model.parseDescribe(JSON.stringify({ loaded: true, loaderVersion: "1.0.0", revision: 8, schema: 1, api: 3 })))
    assert.deepStrictEqual(plain(Model.loaderNotes(described, 8, "1.0.0")).map(n => n.key), ["loader.apiNewer"])
  },

  "comments cite README sections, not a design document that does not ship"() {
    const cited = new RegExp("design \u00a7")
    for (const file of ["Model.js", ...fs.readdirSync(__dirname).filter(name => name.endsWith(".js")).map(name => path.join("tests", name))])
      assert.ok(!cited.test(fs.readFileSync(path.join(pluginDir, file), "utf8")), file)
  },

  "register-failed is a loader code with its own text"() {
    assert.ok(Model.LOADER_CODES.includes("register-failed"))
    assert.strictEqual(Model.errorKey("register-failed"), "error.register-failed")
    assert.strictEqual(typeof catalog["error.register-failed"], "string")
  }
})

for (const [name, body] of Object.entries(tests)) test(name, body)
