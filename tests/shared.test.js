// Tests for Shared.js, the state every bar's panel instance shares.
// Run from the plugin directory: node --test
"use strict"
const assert = require("node:assert")
const { test } = require("node:test")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const source = fs.readFileSync(path.join(__dirname, "..", "Shared.js"), "utf8").replace(/^\.pragma library$/m, "")
const load = () => {
  const context = {}
  vm.runInNewContext(source, context)
  return context
}

test("a capture is taken once while it is fresh", () => {
  const Shared = load()
  const result = { rule: { id: "app" } }
  Shared.putCapture(result, "DP-2", 1000)
  assert.strictEqual(Shared.hasCapture("DP-2", 1000 + Shared.CAPTURE_TTL_MS), true)
  assert.strictEqual(Shared.takeCapture("DP-2", 2000).result, result)
  assert.strictEqual(Shared.hasCapture("DP-2", 2000), false)
  assert.strictEqual(Shared.takeCapture("DP-2", 2000), null)
})

test("a stale capture is dropped", () => {
  const Shared = load()
  Shared.putCapture({ rule: {} }, "DP-2", 1000)
  assert.strictEqual(Shared.hasCapture("DP-2", 1001 + Shared.CAPTURE_TTL_MS), false)
  assert.strictEqual(Shared.takeCapture("DP-2", 1001 + Shared.CAPTURE_TTL_MS), null)
  assert.strictEqual(Shared.hasCapture("DP-2", 1000), false)
})

test("a capture of nothing is still delivered, so the panel can say so", () => {
  const Shared = load()
  Shared.putCapture(null, "DP-2", 5)
  const taken = Shared.takeCapture("DP-2", 6)
  assert.notStrictEqual(taken, null)
  assert.strictEqual(taken.result, null)
})

test("only the panel on the monitor that had the focus takes the capture", () => {
  const Shared = load()
  const result = { rule: { id: "app" } }
  Shared.putCapture(result, "DP-2", 10)
  // An open panel on another monitor neither sees nor consumes it.
  assert.strictEqual(Shared.hasCapture("eDP-1", 20), false)
  assert.strictEqual(Shared.takeCapture("eDP-1", 20), null)
  assert.strictEqual(Shared.takeCapture("", 20), null)
  assert.strictEqual(Shared.hasCapture("DP-2", 30), true)
  assert.strictEqual(Shared.takeCapture("DP-2", 30).result, result)
})

test("a capture for an unknown monitor goes to the first panel that looks", () => {
  const Shared = load()
  Shared.putCapture({ n: 1 }, "", 10)
  assert.strictEqual(Shared.hasCapture("eDP-1", 20), true)
  assert.strictEqual(Shared.takeCapture("eDP-1", 20).result.n, 1)
  assert.strictEqual(Shared.takeCapture("DP-2", 20), null)
})

test("a newer capture replaces one still waiting, and never one already taken", () => {
  const Shared = load()
  Shared.putCapture({ n: 1 }, "DP-2", 10)
  Shared.putCapture({ n: 2 }, "eDP-1", 20)
  assert.strictEqual(Shared.takeCapture("DP-2", 30), null)
  assert.strictEqual(Shared.takeCapture("eDP-1", 30).result.n, 2)
  Shared.putCapture({ n: 3 }, "DP-2", 40)
  const taken = Shared.takeCapture("DP-2", 50)
  Shared.putCapture({ n: 4 }, "DP-2", 60)
  assert.strictEqual(taken.result.n, 3)
  assert.strictEqual(Shared.takeCapture("DP-2", 70).result.n, 4)
})

test("open panels are tracked across instances", () => {
  const Shared = load()
  assert.strictEqual(Shared.anyOpen(), false)
  Shared.setOpen("a", true)
  Shared.setOpen("b", true)
  Shared.setOpen("a", false)
  assert.strictEqual(Shared.anyOpen(), true)
  Shared.setOpen("b", false)
  assert.strictEqual(Shared.anyOpen(), false)
})
