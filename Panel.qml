import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "Shared.js" as Shared

// Window Rules bar widget. Lists the rules in the plugin's rules.json, edits
// them one at a time, captures an open window as a new rule, and saves
// through Store, which reloads Hyprland so the plugin's Lua loader applies
// them. Edits are a draft of this bar's own: they survive closing the panel
// and go on save or discard.
Panel {
  id: root
  moduleName: "io.github.ltecosta.window-rules"
  ipcTarget: moduleName
  manageIpc: false

  // ---------- Draft ----------
  // The list being edited, copied from the store when an edit begins, and
  // the store's currentBase() (revision and text) it came from; null while
  // there is nothing to save.
  property var draftRules: null
  property var draftBase: null
  property bool listDirty: false
  // The rule in the editor, the one it started as, and where it goes (-1 appends).
  property var editorRule: null
  property var editorOriginal: null
  property int editorIndex: -1
  property bool editorIdFollows: false
  // The title the editor's title filter starts with, and its mode.
  property string editorTitle: ""
  property string editorTitleMode: "exact"
  property var editorWarnings: []
  // What Model.repairRule reset in an invalid rule opened for editing.
  property var editorRepairs: []
  // After a conflict: { rule, original } of the rule that was in the editor,
  // kept to reapply over the reloaded list; null otherwise. It goes only
  // when the rule reaches the editor or the user discards it.
  property var conflictRule: null
  // Counts every change to the draft, so a save's completion clears only the
  // version it submitted (savedVersion).
  property int draftVersion: 0
  property int savedVersion: -1
  // This instance's key among every bar's panels in Shared.js.
  readonly property string instanceKey: String(Math.random()).slice(2) + "-" + Date.now()
  Component.onDestruction: Shared.setOpen(instanceKey, false)
  // The output this instance's bar is on, where captures for it belong.
  readonly property string monitorName: {
    var window = button.QsWindow.window
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  // A capture waiting for the user to agree to replace a dirty editor.
  property var pendingCapture: null

  // ---------- View ----------
  property bool setupDismissed: false
  property string noticeKey: ""
  property string errorKey: ""
  property string errorDetail: ""
  property string confirmKind: ""
  property int confirmIndex: -1
  // What the open confirmation is about, frozen when it was asked: the rule
  // to delete (Model.entryIdentity), or the file Restore was offered on
  // (Store.shownFile()).
  property var confirmEntry: null
  property var confirmFile: null
  property var openClients: []
  property bool cursorActive: false
  property var cursorItem: null
  property bool enterPressed: false
  property bool wasOpened: false
  // A reloaded or moved widget briefly overlaps its old instance; register
  // the IPC target only after the old one has released it.
  property bool ipcReady: false

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string barGlyph: String.fromCodePoint(0xF0574)
  readonly property string pluginVersion: Model.manifestVersion(manifestFile.text())

  readonly property var workingRules: draftRules !== null ? draftRules : ruleStore.rules
  readonly property var rows: Model.listRows(workingRules, ruleStore.loader.resolvers, ruleStore.loader.errors)
  readonly property bool editorDirty: editorRule !== null && (editorIndex < 0 || !Model.sameJson(editorRule, editorOriginal))
  readonly property bool loaderMissing: ruleStore.loaderKnown && ruleStore.loader.loaded !== true
  readonly property string mode: Model.panelMode({ ready: ruleStore.ready, loaderKnown: ruleStore.loaderKnown,
    conflict: ruleStore.conflict, fileState: ruleStore.fileState, editorOpen: editorRule !== null,
    loaderMissing: loaderMissing, setupDismissed: setupDismissed })
  readonly property bool fileEditable: ruleStore.fileState === "ok" || ruleStore.fileState === "missing"
  // While a save or restore is in flight the list and the editor are read-only.
  readonly property bool saving: ruleStore.busy
  readonly property string errorText: errorKey !== "" ? Model.fill(translations.t(errorKey), [errorDetail]) : ""
  readonly property bool confirmOpen: confirmKind !== ""
  // The summary strip and the hero's state (Model.summaryCounts).
  readonly property var summary: Model.summaryCounts(rows, ruleStore.loader, ruleStore.fileError)
  // The footer's actions in this view, in order; none hides the footer.
  readonly property var footerKeys: footerActionsFor(mode)

  Commons.Translations { id: translations; directory: Qt.resolvedUrl("i18n") }

  Store {
    id: ruleStore
    pluginId: root.moduleName
    pluginVersion: root.pluginVersion
    onSaved: root.afterSave()
    onFailed: function(key, detail) { root.afterFailure(key, detail) }
  }

  FileView {
    id: manifestFile
    path: decodeURIComponent(String(Qt.resolvedUrl("manifest.json")).replace(/^file:\/\//, ""))
    printErrors: false
    blockLoading: true
  }

  // ---------- Draft ----------

  function beginDraft() {
    if (draftRules !== null) return
    draftRules = Model.clone(ruleStore.rules)
    draftBase = ruleStore.currentBase()
  }

  function clearDraft() {
    draftRules = null
    draftBase = null
    listDirty = false
    closeEditor()
  }

  function closeEditor() {
    draftVersion++
    editorRule = null
    editorOriginal = null
    editorIndex = -1
    editorIdFollows = false
    editorTitle = ""
    editorTitleMode = "exact"
    editorWarnings = []
    editorRepairs = []
    if (!listDirty) { draftRules = null; draftBase = null }
    resetCursor()
  }

  // False, changing nothing, while a save is in flight.
  function editList(next) {
    if (saving) return false
    beginDraft()
    draftVersion++
    draftRules = next
    listDirty = true
    noticeKey = ""
    showError("", "")
    return true
  }

  // The editor's next version of its rule; ignored while a save is in flight.
  function editorEdited(rule, idFollows) {
    if (saving || editorRule === null) return
    draftVersion++
    editorRule = rule
    editorIdFollows = idFollows
  }

  function showError(key, detail) {
    errorKey = key
    errorDetail = detail === undefined ? "" : String(detail)
  }

  // A file holds at most Model.MAX_RULES rules; say so instead of adding one more.
  function roomForRule() {
    if (workingRules.length < Model.MAX_RULES) return true
    noticeKey = ""
    showError("save.tooManyRules", Model.MAX_RULES)
    return false
  }

  function openEditor(rule, index, idFollows, title, titleMode, warnings, repairs) {
    beginDraft()
    draftVersion++
    editorRule = rule
    editorOriginal = Model.clone(rule)
    editorIndex = index
    editorIdFollows = idFollows
    editorTitle = title || ""
    editorTitleMode = titleMode || "exact"
    editorWarnings = warnings || []
    editorRepairs = repairs || []
    editor.reset(rule)
    noticeKey = ""
    showError("", "")
    resetCursor()
    refreshClients()
  }

  // A rule the schema refuses opens repaired (Model.repairRule), dirty
  // against the entry as written, and a save replaces that entry.
  function editRule(index) {
    var row = rows[index]
    if (!row || saving) return
    var rule = workingRules[index]
    if (row.valid) {
      openEditor(Model.clone(rule), index, false, rule.match.title, rule.match.titleMode, [], [])
      return
    }
    var repaired = Model.repairRule(rule, Model.ruleIds(workingRules, index))
    openEditor(repaired.rule, index, false, repaired.rule.match.title, repaired.rule.match.titleMode, [], repaired.fieldErrors)
    editorOriginal = Model.clone(rule)
  }

  function newRule() {
    if (saving || !roomForRule()) return
    var rule = Model.newRule("", Model.ruleIds(workingRules, -1))
    openEditor(rule, -1, true, "", "exact", [], [])
  }

  // A capture never opens under a view that hides the editor, nor while a
  // save is in flight: the view's notice says why (Model.captureBlocker).
  function refuseCapture() {
    var key = Model.captureBlocker(mode, saving)
    if (key === "") return false
    // While the file is read no view can show a notice; the capture just goes.
    if (key !== "state.loading") {
      noticeKey = ""
      showError(key, "")
    }
    return true
  }

  function openCaptured(result) {
    if (refuseCapture()) return
    if (!result) { noticeKey = "capture.none"; showError("", ""); return }
    // A capture is always a new rule, appended, matching the window's app
    // exactly; its title is offered as an exact title.
    if (!roomForRule()) return
    openEditor(result.rule, -1, true, result.title, "exact", result.warnings, [])
  }

  // A capture never replaces unsaved work in the editor without asking.
  function offerCaptured(result) {
    if (refuseCapture()) return
    if (result && editorDirty) {
      pendingCapture = result
      Qt.callLater(function() { root.ask("replaceDraft", -1) })
      return
    }
    openCaptured(result)
  }

  function captureFocused() {
    ruleStore.captureActive(function(result, _monitorName) { root.offerCaptured(result) }, Model.ruleIds(workingRules, -1))
  }

  // Asks the shell to act on the panel of the focused monitor. IPC reaches only
  // the first instance that registered the target, but the shell routes
  // "summon" and "toggle" through the bar to the focused monitor's instance.
  function shellPanel(action) {
    Quickshell.execDetached(["omarchy-shell", "shell", action, root.ipcTarget])
  }

  // The capture shortcut: read the focused window now, before any panel takes
  // the keyboard, and leave it for the panel on the monitor that had the focus.
  function captureForFocusedMonitor() {
    ruleStore.captureActive(function(result, monitorName) {
      Shared.putCapture(result, monitorName, Date.now())
      root.deliverCapture()
    }, Model.ruleIds(workingRules, -1))
  }

  // Every bar's instance of this widget (bar.moduleWidgets) is asked in turn,
  // and only the one on the capture's monitor takes it. Without one, the
  // shell summons the focused monitor's panel, which takes it as it opens
  // when it is on that monitor.
  function deliverCapture() {
    var items = root.bar && typeof root.bar.moduleWidgets === "function" ? root.bar.moduleWidgets(root.moduleName) : []
    for (var i = 0; i < items.length; i++)
      if (items[i] && typeof items[i].receiveCapture === "function" && items[i].receiveCapture()) return
    root.shellPanel("summon")
  }

  // Whether the waiting capture is for this instance's monitor; it is then
  // taken at once if the panel is open, or as it opens.
  function receiveCapture() {
    if (!Shared.hasCapture(monitorName, Date.now())) return false
    if (opened) takeSharedCapture()
    else open()
    return true
  }

  // The capture came from whichever instance owns the IPC target, whose rule
  // ids may differ from this one's draft: give it an id free here.
  function takeSharedCapture() {
    var waiting = Shared.takeCapture(monitorName, Date.now())
    if (waiting === null) return
    var result = waiting.result
    if (result && result.rule)
      result.rule.id = Model.slugId(result.rule.name, Model.ruleIds(workingRules, -1))
    offerCaptured(result)
  }

  function pickedWindow(client, monitors) {
    offerCaptured(Model.ruleFromWindow(client, monitors, Model.ruleIds(workingRules, -1)))
  }

  function refreshClients() {
    ruleStore.listWindows(function(result) { root.openClients = result.clients })
  }

  function startSave(list) {
    savedVersion = draftVersion
    if (ruleStore.save(list, draftBase)) return
    savedVersion = -1
    noticeKey = ""
    showError(Model.saveBlocker({ busy: ruleStore.busy, dirReady: ruleStore.dirReady, fileState: ruleStore.fileState }) || "save.busy", "")
  }

  function saveEditor() {
    if (editorRule === null || ruleStore.busy) return
    var check = Model.checkDraft(draftRules, editorIndex, editorRule, editorOriginal)
    if (!check.ok) return
    startSave(Model.putRule(draftRules, editorIndex, editorRule))
  }

  function saveList() {
    if (!listDirty || ruleStore.busy) return
    startSave(draftRules)
  }

  // A reload or loader problem after the write is the store's lastError,
  // which the list shows; "Saved and reloaded" only when there is none. A
  // draft changed after it was submitted is kept: it is not what was saved.
  function afterSave() {
    var submitted = savedVersion === draftVersion
    savedVersion = -1
    if (submitted || draftRules === null) clearDraft()
    noticeKey = ruleStore.lastError === "" ? "state.saved" : ""
    showError("", "")
  }

  // A conflict reloads the list and keeps the rule that was in the editor,
  // so it can be reapplied over the current rules.
  function afterFailure(key, detail) {
    savedVersion = -1
    if (ruleStore.conflict) {
      conflictRule = editorRule !== null
        ? { rule: Model.clone(editorRule), original: editorIndex >= 0 ? Model.clone(editorOriginal) : null }
        : null
      clearDraft()
    }
    noticeKey = ""
    showError(key, detail)
  }

  // Room is checked before anything is cleared: with the file full, the
  // conflict view stays, with the rule kept and a notice.
  function reapplyConflict() {
    if (conflictRule === null || !fileEditable || saving) return
    var placed = Model.reapplyPlan(ruleStore.rules, conflictRule)
    if (!placed.ok) { noticeKey = ""; showError(placed.reason, placed.detail); return }
    var reloaded = placed.index >= 0 ? Model.clone(ruleStore.rules[placed.index]) : null
    leaveConflict()
    var match = placed.rule.match ? placed.rule.match : {}
    openEditor(placed.rule, placed.index, false, match.title, match.titleMode, [], [])
    // Dirty against the rule as reloaded, not against itself.
    if (reloaded !== null) editorOriginal = reloaded
  }

  function leaveConflict() {
    conflictRule = null
    ruleStore.clearConflict()
    showError("", "")
    resetCursor()
  }

  function discardConflict() {
    if (conflictRule !== null) ask("discardConflict", -1)
    else leaveConflict()
  }

  function cancelEditor() {
    if (editorDirty) ask("discard", -1)
    else closeEditor()
  }

  function discardList() { if (listDirty) ask("discardList", -1) }

  // ---------- Confirmation ----------

  function ask(kind, index) {
    if (kind === "delete" && saving) return
    confirmKind = kind
    confirmIndex = index
    confirmEntry = kind === "delete" ? Model.entryIdentity(workingRules, index) : null
    confirmFile = kind === "restore" ? ruleStore.shownFile() : null
    confirm.selectedIndex = 1
    dialogKeys.forceActiveFocus()
  }

  function answer(accepted) {
    var kind = confirmKind
    var index = confirmIndex
    var entry = confirmEntry
    var shownFile = confirmFile
    var captured = pendingCapture
    confirmKind = ""
    confirmIndex = -1
    confirmEntry = null
    confirmFile = null
    pendingCapture = null
    keyCatcher.forceActiveFocus()
    if (!accepted) return
    if (kind === "delete") {
      // The rule asked about, wherever the list has moved it since.
      var at = Model.findEntry(workingRules, entry)
      if (at < 0) { noticeKey = ""; showError("confirm.changed", ""); return }
      // The next row moves up into its place; at the end, the previous one.
      if (editList(Model.removeRule(workingRules, at)) && cursorActive) cursorToRule(at)
      return
    }
    if (kind === "discard") closeEditor()
    else if (kind === "discardList") clearDraft()
    else if (kind === "discardConflict") leaveConflict()
    else if (kind === "replaceDraft") { closeEditor(); openCaptured(captured) }
    else if (kind === "restore") ruleStore.restoreBackup(shownFile)
    keepCursorAt(index)
  }

  function confirmMessage() {
    if (confirmKind === "delete") {
      return translations.t("confirm.delete.title") + "\n"
        + Model.fill(translations.t("confirm.delete.body"), [confirmEntry ? confirmEntry.name || confirmEntry.id : ""])
    }
    if (confirmKind === "discard") return translations.t("confirm.discard.title") + "\n" + translations.t("confirm.discard.body")
    if (confirmKind === "discardList") return translations.t("confirm.discard.title") + "\n" + translations.t("confirm.discardList.body")
    if (confirmKind === "discardConflict") return translations.t("confirm.discard.title") + "\n" + translations.t("confirm.discardConflict.body")
    if (confirmKind === "restore") return translations.t("confirm.restore.title") + "\n" + translations.t("confirm.restore.body")
    if (confirmKind === "replaceDraft") return translations.t("confirm.replaceDraft.title") + "\n" + translations.t("confirm.replaceDraft.body")
    return ""
  }

  function confirmAccept() {
    if (confirmKind === "delete") return translations.t("confirm.delete.accept")
    if (confirmKind === "restore") return translations.t("confirm.restore.accept")
    if (confirmKind === "replaceDraft") return translations.t("confirm.replaceDraft.accept")
    return translations.t("confirm.discard.accept")
  }

  // ---------- Keyboard cursor ----------
  // Every visible item that defines keyboardEnabled and keyboardActivate is a
  // stop, in declaration order; h/l call keyboardAdjust when it has one.
  function navigationItems() {
    var items = []
    collect(body, items)
    collect(footerArea, items)
    return items
  }

  function collect(item, items) {
    if (!item || item.visible !== true) return
    if (item.keyboardEnabled !== undefined && typeof item.keyboardActivate === "function") {
      if (item.keyboardEnabled === true) items.push(item)
      return
    }
    for (var i = 0; i < item.children.length; i++) collect(item.children[i], items)
  }

  function setCursor(item) {
    if (!item || item.keyboardEnabled !== true) return
    cursorActive = true
    cursorItem = item
  }

  function resetCursor() {
    cursorActive = false
    cursorItem = null
    scroller.contentY = 0
  }

  function keepCursorAt(index) {
    Qt.callLater(function() {
      if (!root.cursorActive) return
      var items = root.navigationItems()
      if (items.indexOf(root.cursorItem) >= 0) return
      root.cursorItem = items.length ? items[Math.max(0, Math.min(index, items.length - 1))] : null
      if (!root.cursorItem) root.cursorActive = false
    })
  }

  function moveCursor(dx, dy) {
    var items = navigationItems()
    if (!items.length) return
    if (dy === 0) {
      if (cursorActive && cursorItem && typeof cursorItem.keyboardAdjust === "function") cursorItem.keyboardAdjust(dx)
      return
    }
    if (!cursorActive || items.indexOf(cursorItem) < 0) {
      setCursor(dy < 0 ? items[items.length - 1] : items[0])
      return
    }
    var next = Math.max(0, Math.min(items.length - 1, items.indexOf(cursorItem) + dy))
    setCursor(items[next])
    scrollIntoView(items[next])
  }

  function inContent(item) {
    for (var parentItem = item; parentItem; parentItem = parentItem.parent)
      if (parentItem === body) return true
    return false
  }

  function scrollIntoView(item) {
    Qt.callLater(function() {
      if (!item || !root.inContent(item)) return
      var top = item.mapToItem(scroller.contentItem, 0, 0).y
      var margin = Style.space(6)
      if (top < scroller.contentY + margin) scroller.contentY = Math.max(0, top - margin)
      else if (top + item.height > scroller.contentY + scroller.height - margin)
        scroller.contentY = Math.min(Math.max(0, scroller.contentHeight - scroller.height),
          top + item.height + margin - scroller.height)
    })
  }

  // Enter, like a click, activates; Space on a rule row enables or disables it.
  function activateCursor() {
    var enter = enterPressed
    enterPressed = false
    if (!cursorActive || !cursorItem) return
    if (!enter && typeof cursorItem.keyboardToggle === "function") cursorItem.keyboardToggle()
    else cursorItem.keyboardActivate()
  }

  function cursorRuleIndex() {
    return cursorActive && cursorItem && cursorItem.ruleIndex !== undefined ? cursorItem.ruleIndex : -1
  }

  function deleteAtCursor() {
    var index = cursorRuleIndex()
    if (mode === "list" && index >= 0 && !saving) ask("delete", index)
  }

  // Once the list has rebuilt its rows: the cursor on the row at `index`,
  // or on the last row when there is none that far, or on the first stop.
  function cursorToRule(index) {
    Qt.callLater(function() {
      var items = root.navigationItems()
      var target = null, lastRow = null
      for (var i = 0; i < items.length; i++) {
        if (items[i].ruleIndex === undefined) continue
        lastRow = items[i]
        if (items[i].ruleIndex === index) target = items[i]
      }
      target = target || lastRow || (items.length ? items[0] : null)
      if (!target) { root.cursorActive = false; root.cursorItem = null; return }
      root.setCursor(target)
      root.scrollIntoView(target)
    })
  }

  function reorderAtCursor(dy) {
    var index = cursorRuleIndex()
    if (mode !== "list" || index < 0 || index + dy < 0 || index + dy >= workingRules.length) return
    if (editList(Model.moveRule(workingRules, index, dy))) cursorToRule(index + dy)
  }

  // The copy goes right after the row and takes the cursor.
  function duplicateAtCursor() {
    var index = cursorRuleIndex()
    if (mode !== "list" || index < 0 || saving || !roomForRule()) return
    if (editList(Model.duplicateRule(workingRules, index))) cursorToRule(index + 1)
  }

  function textKey(value) {
    if (mode === "list") {
      if (value === "n" || value === "N") newRule()
      else if (value === "c" || value === "C") captureFocused()
      else if (value === "d" || value === "D") duplicateAtCursor()
      else if ((value === "s" || value === "S") && listDirty) saveList()
    } else if (mode === "editor" && (value === "s" || value === "S")) {
      saveEditor()
    }
  }

  function leaveInput() { keyCatcher.forceActiveFocus() }

  function stateIpc() {
    return JSON.stringify({ open: Shared.anyOpen(), fileState: ruleStore.fileState, revision: ruleStore.revision, rules: ruleStore.rules.length,
      loaderLoaded: ruleStore.loader.loaded === true, errors: ruleStore.loader.loaded === true ? ruleStore.loader.errors.length : 0 })
  }

  // "4 rules · loader OK": the rule count and what keeps rules from applying.
  function heroMeta() {
    if (mode === "loading") return translations.t("state.loading")
    if (ruleStore.busy) return translations.t("state.saving")
    var count = workingRules.length
    var counted = translations.tn("list.count", count).arg(Commons.I18n.formatNumber(count))
    var state = Model.heroState({ loaderKnown: ruleStore.loaderKnown, fileState: ruleStore.fileState,
      loaderLoaded: ruleStore.loader.loaded === true, errors: summary.errors })
    if (state.key === "") return counted
    var stateText = state.key === "hero.errors"
      ? translations.tn("hero.errors", state.count).arg(Commons.I18n.formatNumber(state.count)) : translations.t(state.key)
    return Model.fill(translations.t("hero.meta"), [counted, stateText])
  }

  function footerActionsFor(view) {
    if (view === "list") return listDirty ? ["save", "discard"] : ["capture", "pick", "new"]
    if (view === "editor") return ["save", "cancel"]
    if (view === "setup") return ["copy", "recheck", "back"]
    if (view === "conflict") return conflictRule !== null ? ["reapply", "discardRule"] : ["back"]
    if (view === "invalid") return ruleStore.backupAvailable ? ["restore"] : []
    return []
  }

  // The title or body of the conflict, invalid or unsupported view's message.
  function fileStateText(part) {
    if (mode !== "conflict" && mode !== "invalid" && mode !== "unsupported") return ""
    return translations.t("state." + mode + "." + part)
  }

  function footerBack() {
    if (mode === "conflict") { discardConflict(); return }
    setupDismissed = true
    resetCursor()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // A view that goes away takes the keyboard with it; give it back to the catcher.
  onModeChanged: if (opened && !confirmOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

  onOpenedChanged: {
    // The handler also runs as the widget is built, closed; that is no look.
    var shown = wasOpened !== opened
    wasOpened = opened
    Shared.setOpen(instanceKey, opened)
    if (!shown || !opened) return
    resetCursor()
    noticeKey = ""
    showError("", "")
    ruleStore.refreshLoader()
    if (editorRule !== null) refreshClients()
    takeSharedCapture()
  }

  Timer {
    interval: 150
    running: true
    onTriggered: root.ipcReady = true
  }

  ShellIpc {
    enabled: root.ipcReady
    target: root.ipcTarget
    // open, toggle and capture act on the focused monitor's panel; close closes
    // whichever panel is open.
    function open(): void { root.shellPanel("summon") }
    function close(): void { root.shellPanel("hide") }
    function toggle(): void { root.shellPanel("toggle") }
    function capture(): string { root.captureForFocusedMonitor(); return "ok" }
    function state(): string { return root.stateIpc() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barGlyph
    tooltipText: translations.t("tooltip")
    // Anything that keeps rules from applying: no loader, a file the panel
    // cannot use, or errors the loader reported.
    active: root.loaderMissing || ruleStore.fileState === "invalid" || ruleStore.fileState === "unsupported"
      || (ruleStore.loader.loaded === true && ruleStore.loader.errors.length > 0)
    onPressed: function(_buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(body.implicitHeight
      + (footerArea.visible ? Style.space(10) + footerArea.implicitHeight : 0), Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      reorderable: root.mode === "list"
      blocked: root.confirmOpen || editor.inputActive || ruleList.inputActive
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onReorderRequested: function(dy) { root.reorderAtCursor(dy) }
      onReturnRequested: root.enterPressed = true
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteAtCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(value, _modifiers) { root.textKey(value) }

      Flickable {
        id: scroller
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: footerArea.top
        anchors.bottomMargin: footerArea.visible ? Style.space(10) : 0
        contentWidth: width
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: body
          width: scroller.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: translations.t("title")
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.barGlyph
                color: button.active ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            // The same capture as the footer's Capture and the c key.
            trailingControl: Component {
              PanelActionButton {
                visible: root.mode === "list"
                bordered: true
                iconText: "󰆟"
                tooltipText: translations.t("action.capture")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.captureFocused()
              }
            }
          }

          // ---------- No loader ----------
          Column {
            visible: root.mode === "setup"
            width: parent.width
            spacing: Style.space(8)

            SectionHeader {
              text: translations.t("section.setup")
              meta: translations.t("section.setup.meta")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Message {
              glyph: "󰀦"
              glyphColor: root.urgent
              title: translations.t("state.noLoader.title")
              body: translations.t("state.noLoader.body")
            }

            BorderSurface {
              width: parent.width
              implicitHeight: blockText.implicitHeight + Style.space(16)
              color: Style.normalFillFor(root.foreground, Commons.Color.accent)
              borderSpec: Border.controlSpec("normal", root.foreground, Commons.Color.accent)
              radius: Style.cornerRadius

              Text {
                id: blockText
                x: Style.space(8)
                y: Style.space(8)
                width: parent.width - Style.space(16)
                textFormat: Text.PlainText
                text: Model.LOAD_BLOCK
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }
            }
          }

          // ---------- Conflict, invalid and unsupported files ----------
          Column {
            visible: root.mode === "conflict" || root.mode === "invalid" || root.mode === "unsupported"
            width: parent.width
            spacing: Style.space(8)

            SectionHeader {
              text: translations.t(root.mode === "conflict" ? "section.conflict" : "section.file")
              meta: root.mode === "conflict" ? translations.t("section.conflict.meta") : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Message {
              glyph: root.mode === "conflict" ? "󰓦" : "󰀦"
              glyphColor: root.mode === "conflict" ? Commons.Color.accent : root.urgent
              title: root.fileStateText("title")
              body: root.fileStateText("body")
            }

            Message {
              visible: root.mode === "conflict" && root.conflictRule !== null
              glyph: Model.targetGlyph(root.conflictRule !== null && root.conflictRule.rule && root.conflictRule.rule.workspace
                ? root.conflictRule.rule.workspace.type : "none")
              body: root.conflictRule !== null
                ? Model.fill(translations.t("state.conflict.kept"), [Model.cleanName(root.conflictRule.rule.name || root.conflictRule.rule.id)])
                : ""
            }

            MessageLine {
              visible: root.mode !== "conflict" && ruleStore.fileError !== ""
              text: translations.t(Model.errorKey(ruleStore.fileError))
            }

            // Why an action here was refused (a restore, a reapply, a capture);
            // the conflict itself is the view's own title.
            MessageLine {
              visible: root.errorKey !== "" && root.errorKey !== Model.CONFLICT_KEY
              text: root.errorText
            }
          }

          // ---------- List ----------
          RuleList {
            id: ruleList
            visible: root.mode === "list"
            width: parent.width
            host: root
            strings: translations
            store: ruleStore
            rows: root.rows
            summary: root.summary
            loaderMissing: root.loaderMissing
            noticeText: root.noticeKey !== "" && root.noticeKey !== "action.copied" ? translations.t(root.noticeKey) : ""
            errorText: root.errorText
            onEditRequested: function(index) { root.editRule(index) }
            enabled: !root.saving
            onMoveRequested: function(index, delta) { root.editList(Model.moveRule(root.workingRules, index, delta)) }
            onEnableRequested: function(index, enabled) { root.editList(Model.setRuleEnabled(root.workingRules, index, enabled)) }
            onDuplicateRequested: function(index) { if (!root.saving && root.roomForRule()) root.editList(Model.duplicateRule(root.workingRules, index)) }
            onDeleteRequested: function(index) { root.ask("delete", index) }
            onWindowPicked: function(client, monitors) { root.pickedWindow(client, monitors) }
            onLeaveInput: root.leaveInput()
          }

          // ---------- Editor ----------
          RuleEditor {
            id: editor
            visible: root.mode === "editor"
            width: parent.width
            host: root
            strings: translations
            rule: root.editorRule
            original: root.editorOriginal
            repairs: root.editorRepairs
            rules: root.draftRules
            index: root.editorIndex
            idFollowsName: root.editorIdFollows
            suggestedTitle: root.editorTitle
            suggestedTitleMode: root.editorTitleMode
            captureWarnings: root.editorWarnings
            monitors: Hyprland.monitors.values
            resolvers: ruleStore.loader.loaded === true ? ruleStore.loader.resolvers : []
            clients: root.openClients
            errorText: root.errorText
            enabled: !root.saving
            onEdited: function(rule, idFollows) { root.editorEdited(rule, idFollows) }
            onLeaveInput: root.leaveInput()
          }
        }
      }

      // Always in view below the content, however long it grows: the
      // view's actions as equal-width buttons.
      Column {
        id: footerArea
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(10)
        visible: root.footerKeys.length > 0
        // Hidden, it takes no room from the content above.
        height: visible ? implicitHeight : 0

        PanelSeparator { foreground: root.foreground }

        Text {
          visible: root.mode === "list" && root.listDirty
          width: parent.width
          textFormat: Text.PlainText
          text: translations.t("list.pending")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          id: footerActions
          width: parent.width
          spacing: Style.space(6)
          readonly property real buttonWidth: (width - spacing * Math.max(0, root.footerKeys.length - 1)) / Math.max(1, root.footerKeys.length)

          PanelButton {
            key: "capture"
            text: translations.t("footer.capture")
            tooltipText: translations.t("action.capture")
            iconText: "󰆟"
            onActivated: root.captureFocused()
          }

          PanelButton {
            key: "pick"
            text: translations.t("footer.pick")
            tooltipText: translations.t("action.pickWindow")
            iconText: "󰖯"
            onActivated: ruleList.openPicker()
          }

          PanelButton {
            key: "new"
            text: translations.t("action.newRule")
            iconText: "󰐕"
            available: root.workingRules.length < Model.MAX_RULES
            unavailableText: Model.fill(translations.t("list.full"), [Model.MAX_RULES])
            onActivated: root.newRule()
          }

          PanelButton {
            key: "save"
            available: !ruleStore.busy && ruleStore.dirReady && (root.mode === "editor" ? editor.valid : root.listDirty)
            text: ruleStore.busy ? translations.t("state.saving") : translations.t("action.save")
            iconText: "󰆓"
            onActivated: root.mode === "editor" ? root.saveEditor() : root.saveList()
          }

          PanelButton {
            key: "discard"
            available: !ruleStore.busy
            text: translations.t("action.discard")
            iconText: "󰜺"
            onActivated: root.discardList()
          }

          PanelButton {
            key: "cancel"
            available: !ruleStore.busy
            text: translations.t("action.cancel")
            iconText: "󰜺"
            onActivated: root.cancelEditor()
          }

          PanelButton {
            key: "copy"
            text: root.noticeKey === "action.copied" ? translations.t("action.copied") : translations.t("action.copy")
            iconText: "󰆏"
            onActivated: root.copyBlock()
          }

          PanelButton {
            key: "recheck"
            text: translations.t("state.noLoader.reload")
            iconText: "󰑐"
            onActivated: ruleStore.refreshLoader()
          }

          PanelButton {
            key: "reapply"
            available: !ruleStore.busy && root.fileEditable
            text: translations.t("action.reapply")
            iconText: "󰑐"
            onActivated: root.reapplyConflict()
          }

          PanelButton {
            key: "discardRule"
            text: translations.t("action.discardRule")
            iconText: "󰜺"
            onActivated: root.discardConflict()
          }

          PanelButton {
            key: "back"
            text: translations.t("footer.back")
            tooltipText: translations.t("action.back")
            iconText: "󰁍"
            onActivated: root.footerBack()
          }

          PanelButton {
            key: "restore"
            available: !ruleStore.busy
            text: translations.t("action.restoreBackup")
            iconText: "󰦛"
            onActivated: root.ask("restore", -1)
          }
        }
      }

      // Holds the keyboard while the dialog is open; the catcher is blocked then.
      Item {
        id: dialogKeys
        Keys.onPressed: function(event) { if (confirm.handleKey(event)) event.accepted = true }
      }

      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: root.confirmMessage()
        cancelText: translations.t("action.cancel")
        confirmText: root.confirmAccept()
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.answer(false)
        onConfirmed: root.answer(true)
      }
    }
  }

  function copyBlock() {
    Quickshell.clipboardText = Model.LOAD_BLOCK
    noticeKey = "action.copied"
  }

  // A footer action, shown when the view lists its `key` (footerKeys).
  component PanelButton: FooterButton {
    id: action
    property string key: ""
    visible: root.footerKeys.indexOf(key) >= 0
    width: footerActions.buttonWidth
    cursorItem: root.cursorItem
    foreground: root.foreground
    fontFamily: root.fontFamily
    onPointerEntered: root.setCursor(action)
  }

  // A state's explanation: a glyph, a title and a dim body.
  component Message: Item {
    id: message
    property string glyph: ""
    property color glyphColor: root.foreground
    property string title: ""
    property string body: ""
    width: parent ? parent.width : implicitWidth
    implicitHeight: messageText.implicitHeight + Style.space(4)

    Text {
      id: messageGlyph
      x: Style.space(8)
      y: Style.space(2)
      width: Style.space(20)
      textFormat: Text.PlainText
      text: message.glyph
      color: message.glyphColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Column {
      id: messageText
      anchors.left: messageGlyph.right
      anchors.leftMargin: Style.space(6)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      y: Style.space(2)
      spacing: Style.space(2)

      Text {
        visible: text !== ""
        width: parent.width
        textFormat: Text.PlainText
        text: message.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        wrapMode: Text.WordWrap
      }

      Text {
        visible: text !== ""
        width: parent.width
        textFormat: Text.PlainText
        text: message.body
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  // An error line under a state's explanation, lined up with its text.
  component MessageLine: Text {
    width: parent ? parent.width : implicitWidth
    leftPadding: Style.space(34)
    rightPadding: Style.space(8)
    textFormat: Text.PlainText
    color: root.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
