import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "Shared.js" as Shared

// Driver for store.smoke.sh's panel run: one Panel without a bar, on its own
// state directory, a fake hyprctl and omarchy-shell first on PATH. Prints
// "SMOKE ok - ..." or "SMOKE not ok - ..." per assertion and
// "SMOKE done <failures>" at the end.
ShellRoot {
  id: root

  readonly property string stateDir: Model.stateDirectory(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME"), "io.github.ltecosta.window-rules")
  readonly property string rulesPath: stateDir + "/rules.json"
  readonly property string fakeDir: Quickshell.env("FAKE_HYPRCTL_DIR")

  property int failures: 0
  property int step: -1
  property string stepName: ""
  property var waiting: null
  property var waitDeadline: 0

  Panel { id: panel }

  function check(condition, message) {
    if (!condition) failures++
    console.log("SMOKE " + (condition ? "ok" : "not ok") + " - panel " + stepName + ": " + message)
  }

  function ids() { return panel.rows.map(function(row) { return row.id }).join(",") }

  function captured(name, title) { return { rule: Model.newRule(name, []), warnings: [], title: title || "" } }

  // then(code) after an argv command; its own process, one at a time.
  function exec(argv, then) {
    tool.then = then
    tool.command = argv
    tool.running = true
  }

  // then() once predicate() holds; a check fails after `ms` otherwise.
  function waitFor(predicate, ms, what, then) {
    waitDeadline = Date.now() + ms
    waiting = { predicate: predicate, what: what, then: then }
  }

  // The first item under `item` for which pred(item) holds.
  function find(item, pred, depth) {
    if (!item || depth > 80) return null
    try { if (pred(item)) return item } catch (error) {}
    var lists = [item.children, item.data]
    for (var l = 0; l < lists.length; l++) {
      var kids = lists[l] || []
      for (var i = 0; i < kids.length; i++) {
        var found = find(kids[i], pred, depth + 1)
        if (found) return found
      }
    }
    return item.contentItem ? find(item.contentItem, pred, depth + 1) : null
  }

  function next() {
    step++
    if (step >= steps.length) { console.log("SMOKE done " + failures); Qt.quit(); return }
    stepName = steps[step].name
    steps[step].run()
  }

  property var steps: [
    { name: "open", run: function() {
      panel.open()
      root.waitFor(function() { return panel.mode === "list" && panel.rows.length === 3 }, 5000, "the list", function() {
        root.check(root.ids() === "a,b,c", "the list shows the file (" + root.ids() + ")")
        root.next()
      })
    } },

    { name: "delete after a reorder", run: function() {
      panel.ask("delete", 1)
      root.check(panel.confirmMessage().indexOf("Beta") >= 0, "the dialog names the rule asked about")
      // Another bar reorders the list while the dialog is open.
      root.exec(["cp", root.fakeDir + "/reordered.json", root.rulesPath], function() {
        root.waitFor(function() { return root.ids() === "b,a,c" }, 5000, "the reordered list", function() {
          root.check(panel.confirmMessage().indexOf("Beta") >= 0, "the dialog still names that rule")
          panel.answer(true)
          root.check(root.ids() === "a,c" && panel.listDirty, "that rule is deleted, not the one now at its index (" + root.ids() + ")")
          root.next()
        })
      })
    } },

    { name: "edits during a save", run: function() {
      panel.saveList()
      root.check(panel.saving, "the save is in flight")
      root.check(panel.editList(Model.moveRule(panel.workingRules, 0, 1)) === false && root.ids() === "a,c", "a list edit is ignored")
      panel.editRule(0)
      root.check(panel.editorRule === null, "no rule opens in the editor")
      panel.offerCaptured(root.captured("During"))
      root.check(panel.editorRule === null && panel.errorKey === "save.busy", "a capture is refused (" + panel.errorKey + ")")
      root.waitFor(function() { return !panel.saving }, 5000, "the save to end", function() {
        root.check(panel.draftRules === null && panel.noticeKey === "state.saved", "the save clears the draft it submitted (" + panel.noticeKey + ")")
        root.next()
      })
    } },

    { name: "captures by monitor", run: function() {
      Shared.putCapture(root.captured("Elsewhere"), "OTHER-9", Date.now())
      root.check(panel.receiveCapture() === false && panel.editorRule === null, "a capture for another monitor is not taken by an open panel")
      root.check(Shared.hasCapture("OTHER-9", Date.now()), "it stays for that monitor's panel")
      Shared.putCapture(root.captured("Here", "Here title"), panel.monitorName, Date.now())
      root.check(panel.receiveCapture() === true && panel.editorRule !== null && panel.editorRule.name === "Here",
        "a capture for this panel's monitor opens in its editor")
      root.check(!Shared.hasCapture(panel.monitorName, Date.now()), "and is taken once")
      root.next()
    } },

    { name: "a 33rd app", run: function() {
      var many = []
      for (var i = 0; i < Model.MAX_CLASSES; i++) many.push("app" + i)
      var rule = Model.clone(panel.editorRule)
      rule.match.classes = many
      panel.editorEdited(rule, false)
      var editor = root.find(panel, function(item) { return typeof item.addTypedApp === "function" }, 0)
      var field = root.find(editor, function(item) {
        return typeof item.placeholderText === "string" && item.placeholderText === editor.strings.t("field.apps.addPlaceholder")
      }, 0)
      root.check(editor !== null && field !== null, "the editor and its Add field are found")
      field.text = "extra"
      editor.addTypedApp()
      root.check(editor.appsFull && panel.editorRule.match.classes.length === Model.MAX_CLASSES && field.text === "extra",
        "Add refuses it with a notice and keeps the text")
      panel.closeEditor()
      root.next()
    } },

    { name: "reapply onto a full file", run: function() {
      root.exec(["cp", root.fakeDir + "/rules-199.json", root.rulesPath], function() {
        root.waitFor(function() { return panel.rows.length === 199 }, 5000, "199 rules", function() {
          panel.newRule()
          var rule = Model.clone(panel.editorRule)
          rule.name = "Kept"
          rule.match.classes = ["org.example.Kept"]
          panel.editorEdited(rule, true)
          // Another bar fills the last place before this save.
          root.exec(["cp", root.fakeDir + "/rules-200.json", root.rulesPath], function() {
            root.waitFor(function() { return JSON.parse(panel.stateIpc()).rules === 200 }, 5000, "the full file", function() {
              panel.saveEditor()
              root.waitFor(function() { return panel.mode === "conflict" && !panel.saving }, 5000, "the conflict", function() {
                root.check(panel.conflictRule !== null && panel.conflictRule.rule.name === "Kept", "the rule in the editor is kept")
                panel.reapplyConflict()
                root.check(panel.mode === "conflict" && panel.conflictRule !== null && panel.conflictRule.rule.name === "Kept",
                  "with no room, reapplying keeps the conflict view and the rule")
                root.check(panel.errorKey === "save.tooManyRules", "and says why (" + panel.errorKey + ")")
                panel.offerCaptured(root.captured("Hidden"))
                root.check(panel.editorRule === null && panel.draftRules === null && panel.conflictRule !== null
                  && panel.errorKey === "capture.conflict", "a capture under the conflict view is refused (" + panel.errorKey + ")")
                panel.discardConflict()
                panel.answer(true)
                root.check(panel.mode === "list" && panel.conflictRule === null, "discarding drops the rule")
                root.next()
              })
            })
          })
        })
      })
    } },

    { name: "invalid file", run: function() {
      root.exec(["truncate", "-s", "0", root.rulesPath], function() {
        root.waitFor(function() { return panel.mode === "invalid" }, 5000, "the invalid view", function() {
          root.check(panel.fileStateText("title") !== "" && panel.fileStateText("body") !== "", "the view has its title and body")
          panel.offerCaptured(root.captured("Hidden"))
          root.check(panel.editorRule === null && panel.draftRules === null && panel.errorKey === "save.notEditable",
            "a capture is refused, with no hidden editor or draft (" + panel.errorKey + ")")
          // Restore is offered on the empty file; another bar repairs it before the answer.
          panel.ask("restore", -1)
          root.exec(["cp", root.fakeDir + "/reordered.json", root.rulesPath], function() {
            root.waitFor(function() { return panel.mode === "list" }, 5000, "the repaired file", function() {
              panel.answer(true)
              root.waitFor(function() { return panel.errorKey !== "" && !panel.saving }, 5000, "the restore to end", function() {
                root.check(panel.errorKey === "restore.changed" && root.ids() === "b,a,c",
                  "the restore offered on the empty file is refused (" + panel.errorKey + ")")
                root.next()
              })
            })
          })
        })
      })
    } }
  ]

  Process {
    id: tool
    property var then: null
    onExited: function(exitCode, _status) {
      var then = tool.then
      tool.then = null
      var code = exitCode
      Qt.callLater(function() { if (then) then(code) })
    }
  }

  Timer {
    interval: 25
    repeat: true
    running: root.waiting !== null
    onTriggered: {
      var w = root.waiting
      if (w.predicate()) { root.waiting = null; w.then(); return }
      if (Date.now() > root.waitDeadline) {
        root.waiting = null
        root.check(false, "timed out waiting for " + w.what)
        console.log("SMOKE done " + root.failures)
        Qt.quit()
      }
    }
  }

  Component.onCompleted: next()
}
