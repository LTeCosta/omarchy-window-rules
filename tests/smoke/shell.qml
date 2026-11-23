import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Driver for store.smoke.sh: two Store instances (two bars) on one state
// directory, a fake hyprctl first on PATH. Prints "SMOKE ok - ..." or
// "SMOKE not ok - ..." per assertion and "SMOKE done <failures>" at the end.
ShellRoot {
  id: root

  readonly property string stateDir: Model.stateDirectory(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME"), "io.github.ltecosta.window-rules")
  readonly property string rulesPath: stateDir + "/rules.json"
  readonly property string backupPath: rulesPath + ".bak"
  readonly property string lockDir: stateDir + "/rules.lock"
  readonly property string fakeDir: Quickshell.env("FAKE_HYPRCTL_DIR")

  property int failures: 0
  property int step: -1
  property string stepName: ""
  property var events: ({ a: [], b: [] })
  property var waiting: null
  property var waitDeadline: 0

  Store {
    id: a
    pluginId: "io.github.ltecosta.window-rules"
    pluginVersion: "0.0.0-smoke"
    onSaved: root.record("a", "saved", "", "")
    onFailed: function(key, detail) { root.record("a", "failed", key, detail) }
  }

  Store {
    id: b
    pluginId: "io.github.ltecosta.window-rules"
    pluginVersion: "0.0.0-smoke"
    onSaved: root.record("b", "saved", "", "")
    onFailed: function(key, detail) { root.record("b", "failed", key, detail) }
  }

  function record(name, kind, key, detail) {
    events[name].push({ kind: kind, key: key, detail: detail })
  }

  function check(condition, message) {
    if (!condition) failures++
    console.log("SMOKE " + (condition ? "ok" : "not ok") + " - " + stepName + ": " + message)
  }

  function readFile(path) {
    var request = new XMLHttpRequest()
    request.open("GET", "file://" + path, false)
    request.send(null)
    return request.status === 0 || request.status === 200 ? request.responseText : null
  }

  function revisionOf(text) {
    var parsed = Model.parseDocument(text)
    return parsed.fileState === "ok" ? parsed.revision : -1
  }

  function rule(id, name) { return { id: id, name: name, match: { "class": "^" + id + "$" } } }

  // then(code, stdout) after an argv command; its own process, one at a time.
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

  function lastEvent(name) { return events[name].length ? events[name][events[name].length - 1] : null }

  function oldTime() { return "@" + String(Math.floor(Date.now() / 1000) - 120) }

  // then(names) with the stale-lock leftovers (rules.lock.stale-*) in the state directory.
  function staleLeftovers(then) {
    exec(["find", stateDir, "-maxdepth", "1", "-name", "rules.lock.stale-*"], function(_code, out) {
      then(out.trim() === "" ? [] : out.trim().split("\n"))
    })
  }

  function synced() {
    var text = readFile(rulesPath)
    return a.loadedText === text && b.loadedText === text && !a.busy && !b.busy
  }

  function next() {
    step++
    if (step >= steps.length) { console.log("SMOKE done " + failures); Qt.quit(); return }
    stepName = steps[step].name
    steps[step].run()
  }

  property var steps: [
    { name: "startup", run: function() {
      root.waitFor(function() { return a.ready && b.ready && a.dirReady && b.dirReady && a.loaderKnown && b.loaderKnown }, 5000, "both stores ready", function() {
        root.check(a.fileState === "ok" && a.revision === 1, "the seeded file reads as revision 1")
        root.exec(["stat", "-c", "%a", root.stateDir], function(code, out) {
          root.check(code === 0 && out.trim() === "700", "an existing state directory is set to mode 700 (got " + out.trim() + ")")
          root.next()
        })
      })
    } },

    { name: "save", run: function() {
      var before = root.readFile(root.rulesPath)
      root.exec(["truncate", "-s", "0", root.fakeDir + "/calls"], function() {
        root.check(a.save(a.rules.concat([root.rule("first", "First")]), a.currentBase()), "save() starts")
        root.waitFor(function() { return !a.busy && root.events.a.length === 1 }, 5000, "the save to end", function() {
          var text = root.readFile(root.rulesPath)
          root.check(root.lastEvent("a").kind === "saved", "the save succeeds")
          root.check(root.revisionOf(text) === 2, "the file has revision 2")
          root.check(text.indexOf('"first"') >= 0, "the new rule is written")
          var written = JSON.parse(text)
          root.check(written.comment === "kept" && written.rules[0].future === true, "unknown fields are kept")
          root.check(root.readFile(root.backupPath) === before, "rules.json.bak holds the previous file")
          root.check(a.lastError === "", "no error after the write (" + a.lastError + ")")
          // The other bar sees the file change and reads the loader again: one repl and
          // one configerrors of its own, besides the saving bar's reload, repl and configerrors.
          var callLines = function() { return root.readFile(root.fakeDir + "/calls").trim().split("\n") }
          root.waitFor(function() { return callLines().length >= 5 }, 5000, "the other bar's refresh", function() {
            var calls = callLines()
            var kinds = calls.map(function(call) { return call.indexOf("repl ") === 0 ? "repl" : call })
            var count = function(kind) { return kinds.filter(function(k) { return k === kind }).length }
            var reloadAt = kinds.indexOf("reload")
            var replAfter = kinds.indexOf("repl", reloadAt + 1)
            root.check(calls.length === 5 && count("reload") === 1 && count("repl") === 2 && count("configerrors") === 2
              && reloadAt >= 0 && replAfter > reloadAt && kinds.indexOf("configerrors", replAfter + 1) > replAfter,
              "hyprctl reload, repl and configerrors run in order, and the other bar reads the loader again (" + calls.join(" | ") + ")")
            root.exec(["stat", "-c", "%a", root.rulesPath, root.backupPath], function(code, out) {
              root.check(code === 0 && out.trim().split("\n").join(",") === "600,600", "the file and the backup have mode 600")
              root.exec(["test", "-e", root.lockDir], function(lockCode) {
                root.check(lockCode !== 0, "the lock is released")
                root.next()
              })
            })
          })
        })
      })
    } },

    { name: "stale base", run: function() {
      root.waitFor(root.synced, 5000, "both stores to read the file", function() {
        var before = root.readFile(root.rulesPath)
        var stale = { revision: 1, text: root.readFile(root.fakeDir + "/seed.json") }
        root.check(b.save(b.rules.concat([root.rule("stale", "Stale")]), stale), "save() starts")
        root.waitFor(function() { return !b.busy && root.events.b.length === 1 }, 5000, "the save to end", function() {
          var event = root.lastEvent("b")
          root.check(event.kind === "failed" && event.key === Model.CONFLICT_KEY, "a stale base is a conflict (" + event.key + ")")
          root.check(b.conflict, "the store reports the conflict")
          root.check(root.readFile(root.rulesPath) === before, "nothing is written")
          root.check(b.loadedText === before, "the store shows the current file")
          b.clearConflict()
          root.exec(["test", "-e", root.lockDir], function(lockCode) {
            root.check(lockCode !== 0, "the lock is released")
            root.next()
          })
        })
      })
    } },

    { name: "concurrent saves", run: function() {
      root.waitFor(root.synced, 5000, "both stores to read the file", function() {
        var aCount = root.events.a.length, bCount = root.events.b.length
        var startedA = a.save(a.rules.concat([root.rule("from-a", "From A")]), a.currentBase())
        var startedB = b.save(b.rules.concat([root.rule("from-b", "From B")]), b.currentBase())
        root.check(startedA && startedB, "both saves start")
        root.waitFor(function() { return !a.busy && !b.busy && root.events.a.length > aCount && root.events.b.length > bCount }, 8000, "both saves to end", function() {
          var ea = root.lastEvent("a"), eb = root.lastEvent("b")
          var wins = (ea.kind === "saved" ? 1 : 0) + (eb.kind === "saved" ? 1 : 0)
          root.check(wins === 1, "exactly one save succeeds (a " + ea.kind + " " + ea.key + ", b " + eb.kind + " " + eb.key + ")")
          var loser = ea.kind === "saved" ? eb : ea
          root.check(loser.key === "state.busyElsewhere" || loser.key === Model.CONFLICT_KEY, "the other is refused as busy or conflicting (" + loser.key + ")")
          var winner = ea.kind === "saved" ? a : b
          var text = root.readFile(root.rulesPath)
          root.check(text === winner.loadedText, "the file is the winner's")
          root.check((text.indexOf('"from-a"') >= 0) !== (text.indexOf('"from-b"') >= 0), "only one of the two new rules is in the file")
          root.check(root.revisionOf(text) === 3, "the file has revision 3")
          a.clearConflict()
          b.clearConflict()
          root.exec(["test", "-e", root.lockDir], function(lockCode) {
            root.check(lockCode !== 0, "the lock is released")
            root.next()
          })
        })
      })
    } },

    { name: "reload failure", run: function() {
      root.waitFor(root.synced, 5000, "both stores to read the file", function() {
        root.exec(["touch", root.fakeDir + "/fail-reload"], function() {
          var count = root.events.a.length
          root.check(a.save(a.rules.concat([root.rule("unreloaded", "Unreloaded")]), a.currentBase()), "save() starts")
          root.waitFor(function() { return !a.busy && root.events.a.length > count }, 5000, "the save to end", function() {
            root.check(root.lastEvent("a").kind === "saved", "the file is saved")
            root.check(root.revisionOf(root.readFile(root.rulesPath)) === 4, "the file has revision 4")
            root.check(a.lastError === "save.savedNotReloaded" && a.lastErrorDetail === "hyprctl reload",
              "the store reports saved but not reloaded (" + a.lastError + ", " + a.lastErrorDetail + ")")
            root.exec(["rm", root.fakeDir + "/fail-reload"], function() {
              root.exec(["test", "-e", root.lockDir], function(lockCode) {
                root.check(lockCode !== 0, "the lock is released")
                root.next()
              })
            })
          })
        })
      })
    } },

    { name: "hung command", run: function() {
      root.waitFor(root.synced, 5000, "both stores to read the file", function() {
        root.exec(["touch", root.fakeDir + "/hang-reload"], function() {
          var count = root.events.a.length
          var started = Date.now()
          a.commandTimeout = 500
          root.check(a.save(a.rules.concat([root.rule("hung", "Hung")]), a.currentBase()), "save() starts")
          root.waitFor(function() { return !a.busy && root.events.a.length > count }, 5000, "the save to end", function() {
            a.commandTimeout = 10000
            root.check(Date.now() - started < 4000, "a hung hyprctl reload is stopped at the time limit")
            root.check(root.lastEvent("a").kind === "saved" && a.lastError === "save.savedNotReloaded" && a.lastErrorDetail === "hyprctl reload",
              "the file is saved and the reload reported as failed (" + a.lastError + ")")
            root.exec(["rm", root.fakeDir + "/hang-reload"], function() { root.next() })
          })
        })
      })
    } },

    { name: "zero-byte file", run: function() {
      root.waitFor(root.synced, 5000, "both stores to read the file", function() {
        var backup = root.readFile(root.backupPath)
        root.exec(["truncate", "-s", "0", root.rulesPath], function() {
          root.waitFor(function() { return a.fileState === "invalid" }, 5000, "the store to see the empty file", function() {
            root.check(a.fileError === "invalid-json", "a zero-byte file is invalid JSON (" + a.fileError + ")")
            root.check(Model.panelMode({ ready: a.ready, loaderKnown: a.loaderKnown, conflict: a.conflict, fileState: a.fileState,
              editorOpen: false, loaderMissing: false, setupDismissed: false }) === "invalid", "the panel shows the invalid state")
            root.check(a.backupAvailable, "the backup is offered")
            root.check(!a.save(a.rules, a.currentBase()), "save() refuses an invalid file")
            var count = root.events.a.length
            root.check(a.restoreBackup(), "restoreBackup() starts")
            root.waitFor(function() { return !a.busy && root.events.a.length > count }, 5000, "the restore to end", function() {
              root.check(root.lastEvent("a").kind === "saved", "the restore succeeds")
              root.check(root.readFile(root.rulesPath) === backup, "the file is the backup")
              root.check(a.fileState === "ok", "the store reads a valid file again")
              root.exec(["test", "-e", root.lockDir], function(lockCode) {
                root.check(lockCode !== 0, "the lock is released")
                root.next()
              })
            })
          })
        })
      })
    } },

    { name: "save after restore", run: function() {
      root.waitFor(root.synced, 5000, "both stores to read the file", function() {
        // The file now equals the backup, so the backup step writes nothing.
        var count = root.events.a.length
        root.check(root.readFile(root.rulesPath) === root.readFile(root.backupPath), "the file equals its backup")
        root.check(a.save(a.rules.concat([root.rule("after-restore", "After restore")]), a.currentBase()), "save() starts")
        root.waitFor(function() { return !a.busy && root.events.a.length > count }, 5000, "the save to end", function() {
          root.check(root.lastEvent("a").kind === "saved", "the save succeeds")
          root.check(root.readFile(root.rulesPath).indexOf('"after-restore"') >= 0, "the new rule is written")
          root.next()
        })
      })
    } },

    { name: "restore after a repair", run: function() {
      root.waitFor(root.synced, 5000, "both stores to read the file", function() {
        root.exec(["truncate", "-s", "0", root.rulesPath], function() {
          root.waitFor(function() { return a.fileState === "invalid" }, 5000, "the store to see the empty file", function() {
            // Restore is offered on the empty file; another bar repairs it before the answer.
            var shown = a.shownFile()
            var repaired = root.readFile(root.fakeDir + "/repaired.json")
            root.exec(["cp", root.fakeDir + "/repaired.json", root.rulesPath], function() {
              root.waitFor(function() { return a.fileState === "ok" && a.loadedText === repaired }, 5000, "the store to see the repair", function() {
                var count = root.events.a.length
                root.check(a.restoreBackup(shown), "restoreBackup() starts")
                root.waitFor(function() { return !a.busy && root.events.a.length > count }, 5000, "the restore to end", function() {
                  var event = root.lastEvent("a")
                  root.check(event.kind === "failed" && event.key === "restore.changed",
                    "a file repaired since Restore was offered is not replaced (" + event.kind + " " + event.key + ")")
                  root.check(root.readFile(root.rulesPath) === repaired, "the repaired file is kept")
                  root.exec(["test", "-e", root.lockDir], function(lockCode) {
                    root.check(lockCode !== 0, "the lock is released")
                    root.next()
                  })
                })
              })
            })
          })
        })
      })
    } },

    { name: "lock held elsewhere", run: function() {
      root.waitFor(root.synced, 5000, "both stores to read the file", function() {
        var before = root.readFile(root.rulesPath)
        root.exec(["mkdir", root.lockDir], function() {
          var count = root.events.a.length
          root.check(a.save(a.rules.concat([root.rule("blocked", "Blocked")]), a.currentBase()), "save() starts")
          root.waitFor(function() { return !a.busy && root.events.a.length > count }, 5000, "the save to end", function() {
            var event = root.lastEvent("a")
            root.check(event.kind === "failed" && event.key === "state.busyElsewhere", "a fresh lock means busy elsewhere (" + event.key + ")")
            root.check(root.readFile(root.rulesPath) === before, "nothing is written")
            root.exec(["test", "-d", root.lockDir], function(lockCode) {
              root.check(lockCode === 0, "another writer's lock is left in place")
              root.exec(["touch", "-d", root.oldTime(), root.lockDir], function() {
                var count2 = root.events.a.length
                root.check(a.save(a.rules.concat([root.rule("after-stale", "After stale")]), a.currentBase()), "save() starts over a stale lock")
                root.waitFor(function() { return !a.busy && root.events.a.length > count2 }, 5000, "the save to end", function() {
                  root.check(root.lastEvent("a").kind === "saved", "a lock older than 30 s is taken over")
                  root.exec(["test", "-e", root.lockDir], function(code) {
                    root.check(code !== 0, "the lock is released")
                    root.staleLeftovers(function(left) {
                      root.check(left.length === 0, "the stale lock is removed (" + left.join(" ") + ")")
                      root.next()
                    })
                  })
                })
              })
            })
          })
        })
      })
    } },

    { name: "stale lock taken meanwhile", run: function() {
      root.waitFor(root.synced, 5000, "both stores to read the file", function() {
        var before = root.readFile(root.rulesPath)
        root.exec(["mkdir", root.lockDir], function() {
          root.exec(["touch", "-d", root.oldTime(), root.lockDir], function() {
            // The stat wrapper answers "stale", then another bar takes a fresh lock.
            root.exec(["cp", root.fakeDir + "/lock-path", root.fakeDir + "/swap-lock"], function() {
              var count = root.events.a.length
              root.check(a.save(a.rules.concat([root.rule("stolen", "Stolen")]), a.currentBase()), "save() starts over a stale lock")
              root.waitFor(function() { return !a.busy && root.events.a.length > count }, 5000, "the save to end", function() {
                var event = root.lastEvent("a")
                root.check(event.kind === "failed" && event.key === "state.busyElsewhere",
                  "a lock taken fresh after the stale check is not taken over (" + event.kind + " " + event.key + ")")
                root.check(root.readFile(root.rulesPath) === before, "nothing is written")
                root.exec(["stat", "-c", "%Y", root.lockDir], function(code, out) {
                  root.check(code === 0 && Date.now() / 1000 - Number(out.trim()) < 30, "the other bar's fresh lock is left in place")
                  root.staleLeftovers(function(left) {
                    root.check(left.length === 0, "no renamed lock is left behind (" + left.join(" ") + ")")
                    root.exec(["rmdir", root.lockDir], function() { root.next() })
                  })
                })
              })
            })
          })
        })
      })
    } },

    { name: "two bars over one stale lock", run: function() {
      root.waitFor(root.synced, 5000, "both stores to read the file", function() {
        root.exec(["mkdir", root.lockDir], function() {
          root.exec(["touch", "-d", root.oldTime(), root.lockDir], function() {
            var aCount = root.events.a.length, bCount = root.events.b.length
            var startedA = a.save(a.rules.concat([root.rule("stale-a", "Stale A")]), a.currentBase())
            var startedB = b.save(b.rules.concat([root.rule("stale-b", "Stale B")]), b.currentBase())
            root.check(startedA && startedB, "both saves start")
            root.waitFor(function() { return !a.busy && !b.busy && root.events.a.length > aCount && root.events.b.length > bCount }, 8000, "both saves to end", function() {
              var ea = root.lastEvent("a"), eb = root.lastEvent("b")
              var wins = (ea.kind === "saved" ? 1 : 0) + (eb.kind === "saved" ? 1 : 0)
              root.check(wins === 1, "exactly one bar takes the stale lock over and saves (a " + ea.kind + " " + ea.key + ", b " + eb.kind + " " + eb.key + ")")
              var text = root.readFile(root.rulesPath)
              root.check((text.indexOf('"stale-a"') >= 0) !== (text.indexOf('"stale-b"') >= 0), "only one of the two new rules is in the file")
              a.clearConflict()
              b.clearConflict()
              root.exec(["test", "-e", root.lockDir], function(lockCode) {
                root.check(lockCode !== 0, "the lock is released")
                root.staleLeftovers(function(left) {
                  root.check(left.length === 0, "no renamed lock is left behind (" + left.join(" ") + ")")
                  root.next()
                })
              })
            })
          })
        })
      })
    } },

    { name: "loader refresh", run: function() {
      root.waitFor(root.synced, 5000, "both stores to read the file", function() {
        root.exec(["cp", root.fakeDir + "/config-errors.src", root.fakeDir + "/config-errors"], function() {
          root.exec(["truncate", "-s", "0", root.fakeDir + "/calls"], function() {
            a.hyprlandEvent("configreloaded")
            root.waitFor(function() { return a.configErrors.length === 1 }, 5000, "the config errors to be read", function() {
              var calls = root.readFile(root.fakeDir + "/calls").trim().split("\n")
              root.check(calls.length === 2 && calls[0].indexOf("repl ") === 0 && calls[1] === "configerrors",
                "a Hyprland config reload runs describe() and configerrors (" + calls.join(" | ") + ")")
              root.check(a.configErrors[0] === "smoke: config error", "the config errors are shown (" + a.configErrors.join(" | ") + ")")
              var count = root.events.a.length
              root.check(a.save(a.rules, { revision: 0, text: "stale" }), "save() starts")
              root.waitFor(function() { return !a.busy && root.events.a.length > count }, 5000, "the save to end", function() {
                root.check(root.lastEvent("a").key === Model.CONFLICT_KEY, "the save is refused as a conflict")
                root.check(a.configErrors.length === 1, "a refused save keeps the config errors it did not read again")
                a.clearConflict()
                root.exec(["truncate", "-s", "0", root.fakeDir + "/calls"], function() {
                  // A hand edit: the other bar's loader state follows the file.
                  root.exec(["cp", root.fakeDir + "/external.json", root.rulesPath], function() {
                    root.waitFor(function() { return b.revision === 50 && b.loader.revision === 50 }, 5000, "the loader to be read again", function() {
                      var after = root.readFile(root.fakeDir + "/calls")
                      root.check(after.indexOf("repl ") >= 0 && after.indexOf("configerrors") >= 0,
                        "an outside change to the file runs describe() and configerrors (" + after.trim().split("\n").join(" | ") + ")")
                      root.exec(["rm", root.fakeDir + "/config-errors"], function() { root.next() })
                    })
                  })
                })
              })
            })
          })
        })
      })
    } },

    { name: "two quick captures", run: function() {
      var results = [], monitors = []
      a.captureActive(function(result, monitor) { results.push(result); monitors.push(monitor) }, [])
      a.captureActive(function(result, monitor) { results.push(result); monitors.push(monitor) }, ["org-example-smoke"])
      root.waitFor(function() { return results.length === 2 }, 5000, "both callbacks", function() {
        root.check(results[0] !== null && results[0].rule.match.mode === "apps" && results[0].rule.match.classes[0] === "org.example.Smoke", "the first capture gets the focused window")
        root.check(results[1] !== null && results[1].rule.id === "org-example-smoke-2", "the second capture gets its own callback and ids")
        root.check(monitors[0] === "SMOKE-1" && monitors[1] === "SMOKE-1", "each capture names the focused display (" + monitors.join(", ") + ")")
        root.next()
      })
    } }
  ]

  Process {
    id: tool
    property var then: null
    stdout: StdioCollector { id: toolOut; waitForEnd: true }
    onExited: function(exitCode, _status) {
      var then = tool.then
      tool.then = null
      var code = exitCode
      Qt.callLater(function() { if (then) then(code, toolOut.text) })
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
