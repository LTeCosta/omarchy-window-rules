import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Model.js" as Model

// The rules file and Hyprland. Reads rules.json from the plugin's state
// directory. A save takes the writer lock (rules.lock, shared by every bar),
// reads the file again and lets Model.savePlan refuse a file that changed
// since the draft began or a document the loader would reject; it then keeps
// the previous valid file as rules.json.bak, writes the new one, releases the
// lock, reloads Hyprland and asks the loader what it registered. What the
// loader reports is read again whenever Hyprland reloads its configuration
// and when the file changes outside this bar. Every command is an argv array
// with a time limit, and nothing is written outside the state directory.
Item {
  id: store

  required property string pluginId
  property string pluginVersion: ""
  // Milliseconds a command may run before it is stopped; its callback then gets -2.
  property int commandTimeout: 10000

  readonly property string stateDir: Model.stateDirectory(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME"), pluginId)
  readonly property string rulesPath: stateDir + "/rules.json"
  readonly property string backupPath: rulesPath + ".bak"
  readonly property string lockDir: stateDir + "/rules.lock"

  // The file as last read.
  property bool ready: false
  property string fileState: "missing"
  property string fileError: ""
  property var doc: null
  property var rules: []
  property real revision: 0
  property bool backupAvailable: false

  // Hyprland and the loader.
  property bool loaderKnown: false
  property var loader: ({ loaded: false })
  property var configErrors: []
  property var notes: []

  // The last save. lastError is a problem after the file was written.
  property bool busy: false
  property bool conflict: false
  property string lastError: ""
  property string lastErrorDetail: ""

  // A save or restore wrote the file (Hyprland's reload may still have failed: see lastError).
  signal saved()
  // Nothing was written; `key` is the i18n key of the reason and `detail` its %1.
  signal failed(string key, string detail)

  property bool dirReady: false
  property string stage: ""
  property bool lockHeld: false
  property var pending: null
  property var saveBase: null
  property var plan: null
  // The text the file state was parsed from (null for no file); loadedKnown
  // is false until a read succeeded, and after an unreadable one.
  property var loadedText: null
  property bool loadedKnown: false
  // The file as the panel showed it when Restore was offered (shownFile()).
  property var restoreBase: null
  property var captureQueue: []

  // Where a draft starts from, for save(): the revision and the exact text
  // shown (null when there is no file).
  function currentBase() {
    return { revision: fileState === "ok" ? revision : 0, text: fileState === "missing" || !loadedKnown ? null : loadedText }
  }

  function reload() { rulesFile.reload() }

  // The file as shown: { known, text }, for a Restore offered now.
  function shownFile() { return { known: loadedKnown, text: loadedText } }

  function clearConflict() { conflict = false }

  // `text` is the file's content, or null when there is no file. Returns
  // whether the file state changed.
  function apply(text) {
    ready = true
    if (loadedKnown && text === loadedText) return false
    loadedKnown = true
    loadedText = text
    var parsed = Model.parseDocument(text)
    fileState = parsed.fileState
    fileError = parsed.error
    doc = parsed.doc
    revision = parsed.revision
    rules = Model.documentRules(parsed)
    return true
  }

  // The watched file as read: a change made outside this bar's own save (a
  // hand edit, another bar's save) also changes what the loader reports.
  function fileRead(text) {
    var external = ready && !busy
    if (apply(text) && external) refreshLoader(true)
  }

  function unreadable() {
    ready = true
    loadedKnown = false
    loadedText = null
    fileState = "invalid"
    fileError = "file-unreadable"
    doc = null
    rules = []
    revision = 0
  }

  // Never refuses: a command started while its process is busy waits its turn.
  function run(proc, argv, done) {
    proc.timeout = commandTimeout
    return proc.begin(argv, done)
  }

  // ---------- Writer lock ----------
  // mkdir is atomic, so one bar at a time holds rules.lock from the fresh
  // read to the replaced file. A lock older than Model.LOCK_STALE_SECONDS is
  // taken to be abandoned and taken over, once.

  function acquireLock(done, retried) {
    run(lockProc, ["mkdir", lockDir], function(code, _out) {
      if (code === 0) { store.lockHeld = true; done(true); return }
      run(lockProc, ["stat", "-c", "%Y", store.lockDir], function(statCode, statOut) {
        var step = Model.lockStep(statCode, statOut, Date.now() / 1000, retried === true)
        if (step === "busy") done(false)
        else if (step === "retry") store.acquireLock(done, true)
        else store.takeOverLock(done)
      })
    })
  }

  // A stale lock is first renamed to a name of this bar's own: a rename is
  // atomic, so of two bars that found the same stale lock only one moves it,
  // and the other, finding nothing to move, is busy. The moved lock is
  // checked again, since another bar may have taken a fresh lock between the
  // stat and the rename: a fresh one goes back where it was and this bar is
  // busy; a stale one is removed and this bar creates a fresh rules.lock.
  function takeOverLock(done) {
    var moved = lockDir + ".stale-" + Math.floor(Math.random() * 1e12).toString(36) + Date.now().toString(36)
    run(lockProc, ["mv", "-T", lockDir, moved], function(code, _out) {
      if (code !== 0) { done(false); return }
      run(lockProc, ["stat", "-c", "%Y", moved], function(statCode, statOut) {
        if (Model.lockStep(statCode, statOut, Date.now() / 1000, false) === "remove")
          run(lockProc, ["rmdir", moved], function(_code, _out) { store.acquireLock(done, true) })
        else
          run(lockProc, ["mv", "-T", "-n", moved, store.lockDir], function(_code, _out) { done(false) })
      })
    })
  }

  function releaseLock(then) {
    if (!lockHeld) { then(); return }
    lockHeld = false
    run(lockProc, ["rmdir", lockDir], function(code, _out) {
      if (code !== 0) console.warn("window-rules: could not remove " + store.lockDir)
      then()
    })
  }

  // ---------- Save ----------

  function begin(firstStage) {
    busy = true
    conflict = false
    lastError = ""
    lastErrorDetail = ""
    notes = []
    stage = "lock"
    acquireLock(function(acquired) {
      if (!acquired) { store.stop("state.busyElsewhere", ""); return }
      store.stage = firstStage
      checkFile.reload()
    })
  }

  // `base` is currentBase() as it was when the caller's rules were made from
  // the file; a file whose text is no longer the base's is a conflict.
  // Returns false, writing nothing, when Model.saveBlocker names a reason.
  function save(list, base) {
    if (Model.saveBlocker({ busy: busy, dirReady: dirReady, fileState: fileState }) !== "") return false
    pending = list
    saveBase = base === undefined ? currentBase() : base
    begin("check")
    return true
  }

  // The fresh read: `text` null when the file is missing, `readable` false
  // when it could not be read.
  function afterCheck(text, readable) {
    if (stage === "check") checked(text, readable)
    else if (stage === "restore-check") restoreChecked(text, readable)
  }

  function checked(text, readable) {
    if (!readable) { unreadable(); stop("error.file-unreadable", ""); return }
    var next = Model.savePlan(saveBase, text, pending)
    if (!next.ok) {
      if (next.reason === Model.CONFLICT_KEY) {
        conflict = true
        apply(text)
      }
      stop(next.reason, next.detail)
      return
    }
    plan = next
    // FileView writes nothing, and reports nothing, for the text it already holds.
    if (next.backup && backupFile.text() !== text) {
      stage = "backup"
      writeWatchdog.restart()
      backupFile.setText(text)
    } else {
      write()
    }
  }

  function afterBackup() {
    backupAvailable = true
    if (stage !== "backup") return
    writeWatchdog.stop()
    write()
  }

  function write() {
    stage = "write"
    writeWatchdog.restart()
    rulesFile.setText(plan.text)
  }

  function writeFailed() {
    if (stage !== "backup" && stage !== "write") return
    writeWatchdog.stop()
    stop("save.writeFailed", "")
  }

  function afterWrite() {
    if (stage !== "write") return
    writeWatchdog.stop()
    apply(plan.text)
    stage = "chmod"
    var argv = ["chmod", "600", rulesPath]
    if (plan.backup) argv.push(backupPath)
    run(chmodProc, argv, function(code, _out) {
      if (code !== 0) store.note("loader.commandFailed", "chmod 600")
      store.releaseLock(store.reloadHyprland)
    })
  }

  // The file is saved by now: a failure here is a note, not a failed save.
  function reloadHyprland() {
    stage = "reload"
    run(reloadProc, ["hyprctl", "reload"], function(code, _out) {
      if (code !== 0) { store.note("save.savedNotReloaded", "hyprctl reload"); store.finish(); return }
      store.stage = "describe"
      run(describeProc, store.describeArgv(), function(describeCode, out) {
        if (describeCode !== 0) store.note("save.savedNotReloaded", "hyprctl repl")
        store.loader = Model.parseDescribe(describeCode === 0 ? out : "")
        store.loaderKnown = true
        store.stage = "configerrors"
        run(errorsProc, ["hyprctl", "configerrors"], function(errorsCode, errorsOut) {
          if (errorsCode !== 0) store.note("loader.commandFailed", "hyprctl configerrors")
          store.configErrors = Model.parseConfigErrors(errorsCode === 0 ? errorsOut : "")
          store.notes = Model.loaderNotes(store.loader, store.plan.revision, store.pluginVersion)
          store.finish()
        })
      })
    })
  }

  function note(key, detail) {
    if (lastError !== "") return
    lastError = key
    lastErrorDetail = detail
  }

  function finish() {
    stage = ""
    busy = false
    pending = null
    saved()
  }

  // Ends a save or restore that wrote nothing, after releasing the lock.
  function stop(key, detail) {
    releaseLock(function() {
      store.stage = ""
      store.busy = false
      store.pending = null
      store.failed(key, detail || "")
    })
  }

  // The last valid version, for a file the panel cannot use. `shown` is
  // shownFile() as it was when Restore was offered (by default, now); the
  // restore is refused, under the lock, when the file is no longer that.
  function restoreBackup(shown) {
    if (busy || !dirReady) return false
    if (Model.parseDocument(backupFile.text()).fileState !== "ok") { failed("restore.none", ""); return false }
    restoreBase = shown === undefined || shown === null ? shownFile() : shown
    begin("restore-check")
    return true
  }

  function restoreChecked(text, readable) {
    var next = Model.restorePlan(restoreBase, { ok: readable, text: text }, backupFile.text())
    if (!next.ok) {
      if (readable) apply(text)
      else unreadable()
      stop(next.reason, next.detail)
      return
    }
    plan = { text: next.text, revision: next.revision, backup: false }
    write()
  }

  // ---------- Loader and windows ----------

  function describeArgv() {
    return ["hyprctl", "repl", "return window_rules and window_rules.describe() or '{\"loaded\":false}'"]
  }

  // The describe() and configerrors steps, run at startup, when the panel
  // opens (`kept` false: what an earlier save reported is dropped), and when
  // Hyprland reloads or the file changes elsewhere (`kept` true). It compares
  // the loader with the file as it is now. Hyprland's config errors are
  // replaced only by a fresh read of them, and not while a save reads its own.
  function refreshLoader(kept) {
    if (!busy && kept !== true) {
      lastError = ""
      lastErrorDetail = ""
      notes = []
    }
    run(probeProc, describeArgv(), function(code, out) {
      store.loader = Model.parseDescribe(code === 0 ? out : "")
      store.loaderKnown = true
      if (!store.busy)
        // The version note holds whatever the file's state; the revision note
        // only when there is a usable file (or none) to compare against.
        store.notes = Model.loaderNotes(store.loader,
          store.fileState === "ok" || store.fileState === "missing" ? store.revision : store.loader.revision,
          store.pluginVersion)
      run(probeErrorsProc, ["hyprctl", "configerrors"], function(errorsCode, errorsOut) {
        if (errorsCode === 0 && !store.busy) store.configErrors = Model.parseConfigErrors(errorsOut)
      })
    })
  }

  // A raw Hyprland event by name; a configuration reload re-reads the loader.
  function hyprlandEvent(name) {
    if (name === "configreloaded") refreshLoader(true)
  }

  // callback(result, monitorName): Model.ruleFromWindow's result for the
  // focused window, or null when nothing has focus, and the name of the
  // display that had the focus ("" when unknown). `existingIds` are the ids
  // to avoid. Captures run one after another, each with its own callback.
  function captureActive(callback, existingIds) {
    if (captureQueue.length >= 4) { Qt.callLater(function() { callback(null, "") }); return }
    captureQueue.push({ callback: callback, ids: existingIds || [] })
    if (captureQueue.length === 1) nextCapture()
  }

  function nextCapture() {
    var job = captureQueue[0]
    run(activeProc, ["hyprctl", "activewindow", "-j"], function(code, out) {
      var client = code === 0 ? Model.parseActiveWindow(out) : null
      run(activeMonitorsProc, ["hyprctl", "monitors", "-j"], function(monitorsCode, monitorsOut) {
        store.captureQueue.shift()
        var monitors = Model.parseMonitors(monitorsCode === 0 ? monitorsOut : "")
        try {
          job.callback(client ? Model.ruleFromWindow(client, monitors, job.ids) : null, Model.focusedMonitorName(monitors, client))
        } finally {
          if (store.captureQueue.length > 0) store.nextCapture()
        }
      })
    })
  }

  // callback({ clients, monitors }) with the open windows and displays.
  function listWindows(callback) {
    run(clientsProc, ["hyprctl", "clients", "-j"], function(code, out) {
      var clients = Model.parseClients(code === 0 ? out : "")
      run(clientsMonitorsProc, ["hyprctl", "monitors", "-j"], function(monitorsCode, monitorsOut) {
        callback({ clients: clients, monitors: Model.parseMonitors(monitorsCode === 0 ? monitorsOut : "") })
      })
    })
  }

  // An existing directory keeps its mode through mkdir -p, so chmod follows.
  Component.onCompleted: run(mkdirProc, ["mkdir", "-p", "-m", "0700", stateDir], function(code, _out) {
    run(mkdirProc, ["chmod", "700", store.stateDir], function(chmodCode, _chmodOut) {
      store.dirReady = code === 0 && chmodCode === 0
      // Know at once whether Hyprland runs the loader, so state() is right
      // before the panel is first opened.
      store.refreshLoader()
    })
  })

  // One argv command at a time; begin() while it runs queues the next one.
  // done(exitCode, stdout) runs once it has ended: -1 when it could not
  // start or the queue is full, -2 when it ran past `timeout` and was killed.
  component Command: Process {
    id: cmd
    property var done: null
    property int lastCode: -1
    property bool timedOut: false
    property int timeout: 10000
    property var queue: []
    property Timer limit: Timer {
      interval: cmd.timeout
      onTriggered: {
        cmd.timedOut = true
        if (cmd.running) cmd.signal(9)
        else Qt.callLater(cmd.finish)
      }
    }
    stdout: StdioCollector { id: output; waitForEnd: true }
    onExited: function(exitCode, _exitStatus) { cmd.lastCode = exitCode }
    onRunningChanged: if (!running) { cmd.limit.stop(); Qt.callLater(cmd.finish) }

    function begin(argv, callback) {
      if (cmd.running || cmd.done !== null) {
        if (cmd.queue.length >= 16) { Qt.callLater(function() { callback(-1, "") }); return false }
        cmd.queue.push({ argv: argv, callback: callback })
        return true
      }
      cmd.lastCode = -1
      cmd.timedOut = false
      cmd.command = argv
      cmd.done = callback
      cmd.limit.restart()
      cmd.running = true
      return true
    }

    function finish() {
      if (cmd.running || cmd.done === null) return
      var callback = cmd.done
      var code = cmd.timedOut ? -2 : cmd.lastCode
      var text = cmd.timedOut ? "" : output.text
      cmd.done = null
      try {
        callback(code, text)
      } finally {
        cmd.next()
      }
    }

    function next() {
      if (cmd.running || cmd.done !== null || cmd.queue.length === 0) return
      var job = cmd.queue.shift()
      cmd.begin(job.argv, job.callback)
    }
  }

  // A backup or file write that never reports back fails the save.
  Timer {
    id: writeWatchdog
    interval: store.commandTimeout
    onTriggered: store.writeFailed()
  }

  Command { id: mkdirProc }
  Command { id: lockProc }
  Command { id: chmodProc }
  Command { id: reloadProc }
  Command { id: describeProc }
  Command { id: errorsProc }
  Command { id: probeProc }
  Command { id: probeErrorsProc }
  Command { id: activeProc }
  Command { id: activeMonitorsProc }
  Command { id: clientsProc }
  Command { id: clientsMonitorsProc }

  Connections {
    target: Hyprland
    function onRawEvent(event) { store.hyprlandEvent(event ? String(event.name) : "") }
  }

  FileView {
    id: rulesFile
    path: store.rulesPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: store.fileRead(text())
    onLoadFailed: function(error) {
      if (error === FileViewError.FileNotFound) store.fileRead(null)
      else store.unreadable()
    }
    onSaved: store.afterWrite()
    onSaveFailed: function(_error) { store.writeFailed() }
  }

  // The fresh read a save or restore checks against.
  FileView {
    id: checkFile
    path: store.rulesPath
    printErrors: false
    onLoaded: store.afterCheck(text(), true)
    onLoadFailed: function(error) { store.afterCheck(null, error === FileViewError.FileNotFound) }
  }

  FileView {
    id: backupFile
    path: store.backupPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: store.backupAvailable = Model.parseDocument(text()).fileState === "ok"
    onLoadFailed: function(_error) { store.backupAvailable = false }
    onSaved: store.afterBackup()
    onSaveFailed: function(_error) { store.writeFailed() }
  }
}
