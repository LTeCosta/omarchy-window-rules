import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The form for one rule. It edits a copy: every change builds the next rule
// and hands it to the panel through edited(), and Model.checkDraft judges it
// against the whole list. The name and identifier come first, then the
// MATCH, PLACEMENT, WINDOW and STATE sections, each a column of rows with
// the label on the left and the control on the right; errors show under the
// row they belong to. While it is disabled (a save in flight) it is
// read-only: no change reaches the panel.
Column {
  id: editor

  required property var host
  required property var strings
  property var rule: null
  // The rule as it was when the editor opened (null for none), so that a
  // pattern this editor cannot compile blocks Save only once it is edited.
  property var original: null
  property var rules: []
  property int index: -1
  property bool idFollowsName: false
  // The title a title filter starts with (a captured window's title, or the
  // rule's own as it opened) and the mode it is written for.
  property string suggestedTitle: ""
  property string suggestedTitleMode: "exact"
  property var captureWarnings: []
  // What Model.repairRule reset when an invalid rule was opened: { field, code }.
  property var repairs: []
  property var monitors: []
  property var resolvers: []
  property var clients: []
  property string errorText: ""

  // Whether the title field is shown: set from the rule when it opens, then
  // only by the title mode buttons, so that emptying the field does not hide it.
  property bool titleWanted: false
  // What the other class mode held, so that switching back restores it
  // (Model.switchMatchMode).
  property var matchStash: ({})
  // The last Add was refused: the rule already lists Model.MAX_CLASSES apps.
  property bool appsFull: false

  readonly property var current: rule !== null ? rule : Model.defaultRule("rule", "")
  readonly property var check: Model.checkDraft(rules, index, current, original)
  readonly property bool valid: rule !== null && check.ok
  readonly property string workspaceType: current.workspace.type
  readonly property string classMode: Model.matchMode(current.match)
  readonly property bool appsMode: classMode === "apps"
  readonly property string titleMode: titleWanted ? Model.titleModeOf(current.match) : "off"
  // The apps of open windows and the rule's own, for the app list.
  readonly property var appOptions: appsMode ? Model.classOptions(clients, current.match.classes) : []
  readonly property var targetOptions: [
    { value: "none", label: strings.t("option.target.none") },
    { value: "id", label: strings.t("option.target.id") },
    { value: "special", label: strings.t("option.target.special") },
    { value: "monitor-slot", label: strings.t("option.target.monitorSlot") },
    { value: "resolver", label: strings.t("option.target.resolver") }
  ]
  readonly property var slotMonitorOptions: Model.monitorOptions(monitors, workspaceType === "monitor-slot" ? current.workspace.monitor : "")
  readonly property var monitorChoices: Model.monitorOptions(monitors, current.monitor)
  readonly property var resolverChoices: Model.resolverOptions(resolvers, workspaceType === "resolver" ? current.workspace.resolver : "")
  readonly property var warningKeys: check.warnings.concat(captureWarnings).map(function(code) { return Model.warningKey(code) })
  // null when a pattern cannot be checked here.
  readonly property var matches: Model.previewCount(current, clients)
  readonly property bool inputActive: nameField.activeFocus || idField.activeFocus || classField.activeFocus
    || titleField.activeFocus || addAppField.activeFocus || appsSelect.popupOpen || specialRow.editing
    || workspaceIdField.editing || slotField.editing || argField.editing || widthField.editing || heightField.editing
    || xField.editing || yField.editing || opacityField.editing
    || targetRow.popupOpen || slotMonitorRow.popupOpen || resolverRow.popupOpen || monitorRow.popupOpen

  readonly property color foreground: host.foreground
  readonly property color urgent: host.urgent
  readonly property color dim: host.dim
  readonly property string fontFamily: host.fontFamily
  // Rows draw their text this far in from the panel edge; blocks under a
  // row (fields, notes, errors) line up with it.
  readonly property real inset: Style.space(8)

  signal edited(var rule, bool idFollows)
  signal leaveInput()

  // Called by the panel when `next` opens in the editor.
  function reset(next) {
    titleWanted = next !== null && typeof next === "object" && next.match !== null && typeof next.match === "object"
      && typeof next.match.title === "string" && next.match.title !== ""
    matchStash = ({})
    appsFull = false
    addAppField.text = ""
  }

  function change(mutate, idFollows) {
    if (rule === null || !enabled) return
    var next = Model.clone(rule)
    mutate(next)
    edited(next, idFollows === undefined ? idFollowsName : idFollows)
  }

  // The check's error for `field`, or else what opening it reset there.
  function fieldError(field) {
    if (check.field === field) return strings.t(Model.matchErrorKey(check.status, current.match))
    var notes = []
    for (var i = 0; i < repairs.length; i++)
      if (repairs[i].field === field)
        notes.push(Model.fill(strings.t("editor.repairedField"), [strings.t(Model.matchErrorKey(repairs[i].code, current.match))]))
    return notes.join("\n")
  }

  function patternError(code, field) {
    if (code !== "") return strings.t(Model.matchErrorKey(code, current.match))
    return fieldError(field)
  }

  function setName(text) {
    var follows = idFollowsName
    change(function(next) {
      next.name = text
      if (follows) next.id = Model.slugId(text, Model.ruleIds(editor.rules, editor.index))
    })
  }

  function setClassMode(mode) {
    var switched = Model.switchMatchMode(current.match, mode, matchStash)
    matchStash = switched.stash
    change(function(next) { next.match = switched.match })
  }

  // The app list as the multi-select hands it back (a Qt list is fine).
  // More than MAX_CLASSES chosen keeps the first ones and says so, as Add does.
  function setClasses(values) {
    var classes = Model.uniqueClasses(values)
    appsFull = classes.length === Model.MAX_CLASSES && Model.arrayLike(values).length > classes.length
    change(function(next) { next.match.classes = classes })
  }

  // Adds the class typed in the add field, which need not have a window open.
  // A full list refuses it, keeping the text, and says so.
  function addTypedApp() {
    var value = Model.typedClass(addAppField.text)
    if (value === "" || rule === null || !enabled) return
    var added = Model.addClass(current.match.classes, value)
    appsFull = added.refused
    if (added.refused) return
    addAppField.text = ""
    change(function(next) { next.match.classes = added.classes })
  }

  // "off", "exact" or "regex". Turning the filter on starts from the
  // suggested title when the field is empty; switching modes keeps the text.
  function setTitleMode(choice) {
    if (choice === "off") {
      titleWanted = false
      change(function(next) { next.match.title = "" })
      return
    }
    var wasOn = titleWanted
    titleWanted = true
    var suggestion = Model.titleSuggestion(suggestedTitle, suggestedTitleMode, choice)
    change(function(next) {
      if (!wasOn || next.match.title === "") next.match.title = suggestion
      next.match.titleMode = choice
    })
  }

  function setTarget(type) {
    var monitor = slotMonitorOptions.length ? slotMonitorOptions[0].value : ""
    var resolver = resolverChoices.length ? resolverChoices[0].value : ""
    change(function(next) { next.workspace = Model.workspaceFor(type, next.workspace, monitor, resolver) })
  }

  function setPosition(type) {
    change(function(next) {
      var previous = next.position
      next.position = type === "at"
        ? { type: "at", x: previous.type === "at" ? previous.x : Model.MIN_POSITION, y: previous.type === "at" ? previous.y : Model.MIN_POSITION }
        : { type: type }
    })
  }

  // The option `step` places after `value`, wrapping around the ends.
  function cycle(options, value, step) {
    var values = Model.arrayLike(options).map(function(option) { return typeof option === "object" ? option.value : option })
    var count = values.length
    if (count === 0) return value
    var at = values.indexOf(value)
    if (at < 0) return values[step > 0 ? 0 : count - 1]
    return values[((at + step) % count + count) % count]
  }

  spacing: Style.space(2)

  Keys.onEscapePressed: editor.leaveInput()

  FieldNote {
    visible: editor.repairs.length > 0
    text: editor.strings.t("editor.repaired")
    color: editor.urgent
  }

  // ---------- Name and identifier ----------
  Column {
    width: parent.width
    spacing: Style.space(4)

    TextField {
      id: nameField
      readonly property bool keyboardEnabled: visible
      function keyboardActivate() { forceActiveFocus() }
      width: parent.width
      text: editor.current.name
      placeholderText: editor.strings.t("field.name")
      foreground: editor.foreground
      font.family: editor.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      hasCursor: editor.host.cursorItem === nameField
      onHoveredChanged: if (hovered) editor.host.setCursor(nameField)
      onTextEdited: editor.setName(text)
      onAccepted: editor.leaveInput()
    }

    Row {
      x: editor.inset
      width: parent.width - editor.inset
      spacing: Style.space(6)

      Text {
        id: idLabel
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: editor.strings.t("field.id.inline")
        color: editor.dim
        font.family: editor.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      TextField {
        id: idField
        readonly property bool keyboardEnabled: visible
        function keyboardActivate() { forceActiveFocus() }
        width: parent.width - idLabel.width - parent.spacing
        text: editor.current.id
        placeholderText: editor.strings.t("field.id")
        foreground: editor.dim
        verticalPadding: Style.space(3)
        horizontalPadding: Style.space(6)
        font.family: editor.fontFamily
        font.pixelSize: Style.font.caption
        hasCursor: editor.host.cursorItem === idField
        onHoveredChanged: if (hovered) editor.host.setCursor(idField)
        onTextEdited: { var value = text; editor.change(function(next) { next.id = value }, false) }
        onAccepted: editor.leaveInput()
      }
    }
  }
  FieldError { message: editor.fieldError("name") }
  FieldError { message: editor.fieldError("id") }

  // ---------- Match ----------
  SectionHeader {
    gap: Style.space(12)
    text: editor.strings.t("section.match")
    meta: editor.matches === null ? editor.strings.t("preview.unavailable")
      : editor.strings.tn("preview.matches", editor.matches).arg(Commons.I18n.formatNumber(editor.matches))
    metaTooltip: editor.strings.t("preview.hint")
    foreground: editor.foreground
    fontFamily: editor.fontFamily
  }

  ChoiceRow {
    id: classModeRow
    title: editor.strings.t("field.matchBy")
    detail: editor.strings.t(editor.appsMode ? "row.matchBy.apps" : "row.matchBy.regex")
    choices: [
      { value: "apps", label: editor.strings.t("option.match.apps") },
      { value: "regex", label: editor.strings.t("option.match.regex") }
    ]
    value: editor.classMode
    onChosen: function(choice) { editor.setClassMode(choice) }
  }

  // Apps: exact window classes, picked from the open windows or typed.
  FieldBlock {
    visible: editor.appsMode

    MultiSelect {
      id: appsSelect
      readonly property bool keyboardEnabled: visible
      function keyboardActivate() { open() }
      width: parent.width
      showLabel: false
      options: editor.appOptions
      values: editor.appsMode ? editor.current.match.classes : []
      placeholderText: editor.strings.t("field.apps.placeholder")
      emptyText: editor.strings.t("field.apps.empty")
      noSelectionText: editor.strings.t("field.apps.none")
      foreground: editor.foreground
      fontFamily: editor.fontFamily
      hasCursor: editor.host.cursorItem === appsSelect
      onHovered: function(on) { if (on) editor.host.setCursor(appsSelect) }
      // The kit sets `values` itself on a choice, which ends its binding.
      onChanged: function(values) {
        editor.setClasses(values)
        appsSelect.values = Qt.binding(function() { return editor.appsMode ? editor.current.match.classes : [] })
      }
      onPopupOpenChanged: {
        if (popupOpen) editor.host.refreshClients()
        else editor.leaveInput()
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: addAppField
        readonly property bool keyboardEnabled: visible
        function keyboardActivate() { forceActiveFocus() }
        width: parent.width - addAppButton.width - parent.spacing
        placeholderText: editor.strings.t("field.apps.addPlaceholder")
        foreground: editor.foreground
        font.family: editor.fontFamily
        font.pixelSize: Style.font.bodySmall
        hasCursor: editor.host.cursorItem === addAppField
        onHoveredChanged: if (hovered) editor.host.setCursor(addAppField)
        onTextEdited: editor.appsFull = false
        onAccepted: { editor.addTypedApp(); editor.leaveInput() }
      }

      Button {
        id: addAppButton
        readonly property bool keyboardEnabled: visible && enabled
        function keyboardActivate() { if (enabled) editor.addTypedApp() }
        anchors.verticalCenter: addAppField.verticalCenter
        enabled: Model.typedClass(addAppField.text) !== ""
        bordered: true
        text: editor.strings.t("action.addApp")
        iconText: "󰐕"
        foreground: editor.foreground
        fontFamily: editor.fontFamily
        fontSize: Style.font.bodySmall
        hasCursor: editor.host.cursorItem === addAppButton
        onHovered: function(on) { if (on) editor.host.setCursor(addAppButton) }
        onClicked: keyboardActivate()
      }
    }

    FieldNote { width: parent.width; leftPadding: 0; rightPadding: 0; text: editor.strings.t("field.apps.add") }
  }
  FieldError { message: editor.appsMode && editor.appsFull ? Model.fill(editor.strings.t("field.apps.full"), [Model.MAX_CLASSES]) : "" }

  // Regex: one RE2 pattern for the class.
  FieldBlock {
    visible: !editor.appsMode

    TextField {
      id: classField
      readonly property bool keyboardEnabled: visible
      function keyboardActivate() { forceActiveFocus() }
      width: parent.width
      text: Model.matchField(editor.current, "class")
      placeholderText: editor.strings.t("field.class")
      foreground: editor.foreground
      font.family: editor.fontFamily
      font.pixelSize: Style.font.bodySmall
      hasCursor: editor.host.cursorItem === classField
      onHoveredChanged: if (hovered) editor.host.setCursor(classField)
      onTextEdited: { var value = text; editor.change(function(next) { next.match["class"] = value }) }
      onAccepted: editor.leaveInput()
    }
  }
  FieldError { message: editor.patternError(editor.check.classError, "class") }

  ChoiceRow {
    id: titleModeRow
    title: editor.strings.t("field.titleMatch")
    detail: editor.strings.t("row.title.detail")
    choices: [
      { value: "off", label: editor.strings.t("option.title.off") },
      { value: "exact", label: editor.strings.t("option.title.exact") },
      { value: "regex", label: editor.strings.t("option.title.regex") }
    ]
    value: editor.titleMode
    onChosen: function(choice) { editor.setTitleMode(choice) }
  }

  FieldBlock {
    visible: editor.titleWanted

    TextField {
      id: titleField
      readonly property bool keyboardEnabled: visible
      function keyboardActivate() { forceActiveFocus() }
      width: parent.width
      text: editor.current.match.title
      placeholderText: editor.strings.t(editor.titleMode === "exact" ? "field.title.exact" : "field.title")
      foreground: editor.foreground
      font.family: editor.fontFamily
      font.pixelSize: Style.font.bodySmall
      hasCursor: editor.host.cursorItem === titleField
      onHoveredChanged: if (hovered) editor.host.setCursor(titleField)
      onTextEdited: { var value = text; editor.change(function(next) { next.match.title = value }) }
      onAccepted: editor.leaveInput()
    }

    FieldNote { width: parent.width; leftPadding: 0; rightPadding: 0; text: editor.strings.t("field.title.hint") }
  }
  // Also shown with the filter off, for a title that opening the rule reset.
  FieldError { message: editor.patternError(editor.check.titleError, "title") }

  SwitchRow {
    id: initialRow
    title: editor.strings.t("toggle.initial")
    detail: editor.strings.t("toggle.initial.hint")
    checked: editor.current.match.initial === true
    onToggled: editor.change(function(next) { next.match.initial = next.match.initial !== true })
  }

  // ---------- Placement ----------
  SectionHeader {
    gap: Style.space(12)
    text: editor.strings.t("section.placement")
    foreground: editor.foreground
    fontFamily: editor.fontFamily
  }

  DropdownRow {
    id: targetRow
    title: editor.strings.t("field.target")
    detail: editor.strings.t("row.target.detail")
    options: editor.targetOptions
    current: editor.workspaceType
    onChosen: function(choice) { editor.setTarget(choice) }
  }

  EditorStepper {
    id: workspaceIdField
    visible: editor.workspaceType === "id"
    title: editor.strings.t("field.workspaceId")
    detail: editor.strings.t("row.workspaceId.detail")
    from: Model.MIN_WORKSPACE_ID
    to: Model.MAX_WORKSPACE_ID
    value: editor.workspaceType === "id" ? editor.current.workspace.id : Model.MIN_WORKSPACE_ID
    onModified: function(value) { editor.change(function(next) { next.workspace.id = value }) }
  }

  SettingRow {
    id: specialRow
    readonly property bool editing: specialField.activeFocus
    readonly property bool keyboardEnabled: visible
    function keyboardActivate() { specialField.forceActiveFocus() }
    visible: editor.workspaceType === "special"
    title: editor.strings.t("field.specialName")
    detail: editor.strings.t("row.specialName.detail")
    foreground: editor.foreground
    fontFamily: editor.fontFamily
    hasCursor: editor.host.cursorItem === specialRow
    onPointerEntered: editor.host.setCursor(specialRow)
    onClicked: keyboardActivate()

    TextField {
      id: specialField
      width: Style.space(150)
      text: editor.workspaceType === "special" ? editor.current.workspace.name : ""
      foreground: editor.foreground
      verticalPadding: Style.space(4)
      font.family: editor.fontFamily
      font.pixelSize: Style.font.bodySmall
      onHoveredChanged: if (hovered) editor.host.setCursor(specialRow)
      onTextEdited: { var value = text; editor.change(function(next) { next.workspace.name = value }) }
      onAccepted: editor.leaveInput()
    }
  }

  DropdownRow {
    id: slotMonitorRow
    visible: editor.workspaceType === "monitor-slot" && editor.slotMonitorOptions.length > 0
    title: editor.strings.t("field.monitorSlot.monitor")
    detail: editor.strings.t("row.slotMonitor.detail")
    options: editor.slotMonitorOptions
    current: editor.workspaceType === "monitor-slot" ? editor.current.workspace.monitor : ""
    onChosen: function(choice) { editor.change(function(next) { next.workspace.monitor = choice }) }
  }
  FieldNote {
    visible: editor.workspaceType === "monitor-slot" && editor.slotMonitorOptions.length === 0
    text: editor.strings.t("field.monitor.none")
  }

  EditorStepper {
    id: slotField
    visible: editor.workspaceType === "monitor-slot"
    title: editor.strings.t("field.monitorSlot.slot")
    detail: editor.strings.t("row.slot.detail")
    from: Model.MIN_SLOT
    to: Model.MAX_SLOT
    value: editor.workspaceType === "monitor-slot" ? editor.current.workspace.slot : Model.MIN_SLOT
    onModified: function(value) { editor.change(function(next) { next.workspace.slot = value }) }
  }

  DropdownRow {
    id: resolverRow
    visible: editor.workspaceType === "resolver" && editor.resolverChoices.length > 0
    title: editor.strings.t("field.resolver")
    detail: editor.strings.t("row.resolver.detail")
    options: editor.resolverChoices
    current: editor.workspaceType === "resolver" ? editor.current.workspace.resolver : ""
    onChosen: function(choice) { editor.change(function(next) { next.workspace.resolver = choice }) }
  }
  FieldNote {
    visible: editor.workspaceType === "resolver" && editor.resolverChoices.length === 0
    text: editor.strings.t("field.resolver.none")
  }

  EditorStepper {
    id: argField
    visible: editor.workspaceType === "resolver"
    title: editor.workspaceType === "resolver" && Model.resolverArgLabel(editor.resolvers, editor.current.workspace.resolver) !== ""
      ? Model.resolverArgLabel(editor.resolvers, editor.current.workspace.resolver) : editor.strings.t("field.resolver.arg")
    detail: editor.strings.t("row.arg.detail")
    from: Model.MIN_ARG
    to: Model.MAX_ARG
    value: editor.workspaceType === "resolver" ? editor.current.workspace.arg : Model.MIN_ARG
    onModified: function(value) { editor.change(function(next) { next.workspace.arg = value }) }
  }
  FieldError { message: editor.fieldError("workspace") }

  ChoiceRow {
    id: focusRow
    visible: editor.workspaceType !== "none"
    title: editor.strings.t("field.focus")
    detail: editor.strings.t(editor.current.follow ? "row.focus.follow" : "row.focus.silent")
    choices: [
      { value: "follow", label: editor.strings.t("option.focus.follow") },
      { value: "silent", label: editor.strings.t("option.focus.silent") }
    ]
    value: editor.current.follow ? "follow" : "silent"
    onChosen: function(choice) { editor.change(function(next) { next.follow = choice === "follow" }) }
  }

  // ---------- Window ----------
  SectionHeader {
    gap: Style.space(12)
    text: editor.strings.t("section.window")
    foreground: editor.foreground
    fontFamily: editor.fontFamily
  }

  ChoiceRow {
    id: layoutRow
    title: editor.strings.t("field.layout")
    detail: editor.strings.t("row.layout.detail")
    choices: [
      { value: "default", label: editor.strings.t("option.layout.default") },
      { value: "tile", label: editor.strings.t("option.layout.tile") },
      { value: "float", label: editor.strings.t("option.layout.float") }
    ]
    value: editor.current.layout
    onChosen: function(choice) { editor.change(function(next) { next.layout = choice }) }
  }
  FieldError { message: editor.fieldError("layout") }

  SwitchRow {
    id: sizeToggle
    title: editor.strings.t("toggle.setSize")
    detail: editor.strings.t("toggle.setSize.hint")
    checked: editor.current.size !== null
    onToggled: editor.change(function(next) { next.size = next.size === null ? [800, 600] : null })
  }

  EditorStepper {
    id: widthField
    visible: editor.current.size !== null
    step: 10
    unit: editor.strings.t("unit.px")
    title: editor.strings.t("field.width")
    from: Model.MIN_SIZE
    to: Model.MAX_GEOMETRY
    value: editor.current.size !== null ? editor.current.size[0] : 800
    onModified: function(value) { editor.change(function(next) { if (next.size !== null) next.size[0] = value }) }
  }

  EditorStepper {
    id: heightField
    visible: editor.current.size !== null
    step: 10
    unit: editor.strings.t("unit.px")
    title: editor.strings.t("field.height")
    from: Model.MIN_SIZE
    to: Model.MAX_GEOMETRY
    value: editor.current.size !== null ? editor.current.size[1] : 600
    onModified: function(value) { editor.change(function(next) { if (next.size !== null) next.size[1] = value }) }
  }
  FieldError { message: editor.fieldError("size") }

  ChoiceRow {
    id: positionRow
    title: editor.strings.t("field.position")
    detail: editor.strings.t("row.position.detail")
    choices: [
      { value: "none", label: editor.strings.t("option.position.none") },
      { value: "center", label: editor.strings.t("option.position.center") },
      { value: "at", label: editor.strings.t("option.position.at") }
    ]
    value: editor.current.position.type
    onChosen: function(choice) { editor.setPosition(choice) }
  }

  EditorStepper {
    id: xField
    visible: editor.current.position.type === "at"
    step: 10
    unit: editor.strings.t("unit.px")
    title: editor.strings.t("field.x")
    from: Model.MIN_POSITION
    to: Model.MAX_GEOMETRY
    value: editor.current.position.type === "at" ? editor.current.position.x : Model.MIN_POSITION
    onModified: function(value) { editor.change(function(next) { if (next.position.type === "at") next.position.x = value }) }
  }

  EditorStepper {
    id: yField
    visible: editor.current.position.type === "at"
    step: 10
    unit: editor.strings.t("unit.px")
    title: editor.strings.t("field.y")
    from: Model.MIN_POSITION
    to: Model.MAX_GEOMETRY
    value: editor.current.position.type === "at" ? editor.current.position.y : Model.MIN_POSITION
    onModified: function(value) { editor.change(function(next) { if (next.position.type === "at") next.position.y = value }) }
  }
  FieldError { message: editor.fieldError("position") }

  SwitchRow {
    id: monitorToggle
    title: editor.strings.t("toggle.setMonitor")
    detail: editor.strings.t("toggle.setMonitor.hint")
    checked: editor.current.monitor !== null
    onToggled: {
      var first = editor.monitorChoices.length ? editor.monitorChoices[0].value : ""
      editor.change(function(next) { next.monitor = next.monitor === null ? first : null })
    }
  }

  DropdownRow {
    id: monitorRow
    visible: editor.current.monitor !== null && editor.monitorChoices.length > 0
    title: editor.strings.t("field.monitor")
    options: editor.monitorChoices
    current: editor.current.monitor !== null ? editor.current.monitor : ""
    onChosen: function(choice) { editor.change(function(next) { next.monitor = choice }) }
  }
  FieldNote {
    visible: editor.current.monitor !== null && editor.monitorChoices.length === 0
    text: editor.strings.t("field.monitor.none")
  }
  FieldError { message: editor.fieldError("monitor") }

  // ---------- State ----------
  SectionHeader {
    gap: Style.space(12)
    text: editor.strings.t("section.state")
    foreground: editor.foreground
    fontFamily: editor.fontFamily
  }

  FlagRow { key: "enabled"; title: editor.strings.t("toggle.enabled"); detail: editor.strings.t("toggle.enabled.hint") }
  FlagRow { key: "fullscreen"; title: editor.strings.t("toggle.fullscreen"); detail: editor.strings.t("toggle.fullscreen.hint") }
  FlagRow { key: "maximize"; title: editor.strings.t("toggle.maximize"); detail: editor.strings.t("toggle.maximize.hint") }
  FlagRow { key: "pin"; title: editor.strings.t("toggle.pin"); detail: editor.strings.t("toggle.pin.hint") }
  FlagRow { key: "noInitialFocus"; title: editor.strings.t("toggle.noInitialFocus"); detail: editor.strings.t("toggle.noInitialFocus.hint") }
  FieldError { message: editor.fieldError("flags") }

  SwitchRow {
    id: opacityToggle
    title: editor.strings.t("toggle.setOpacity")
    detail: editor.strings.t("toggle.setOpacity.hint")
    checked: editor.current.opacity !== null
    onToggled: editor.change(function(next) { next.opacity = next.opacity === null ? 0.9 : null })
  }

  // Shown as a percent, stored as a fraction.
  EditorStepper {
    id: opacityField
    visible: editor.current.opacity !== null
    step: 5
    unit: "%"
    title: editor.strings.t("field.opacity")
    from: Math.round(Model.MIN_OPACITY * 100)
    to: Math.round(Model.MAX_OPACITY * 100)
    value: editor.current.opacity !== null ? Math.round(editor.current.opacity * 100) : to
    onModified: function(value) { editor.change(function(next) { next.opacity = value / 100 }) }
  }
  FieldError { message: editor.fieldError("opacity") }

  // ---------- Notes ----------
  FieldError { message: editor.fieldError("rule") }

  Repeater {
    model: editor.warningKeys

    delegate: FieldNote {
      required property var modelData
      text: editor.strings.t(modelData)
    }
  }

  FieldError { message: editor.errorText }

  // Fields, lists and notes under a row, lined up with the rows' text.
  component FieldBlock: Column {
    x: editor.inset
    width: editor.width - editor.inset * 2
    spacing: Style.space(4)
    topPadding: Style.space(2)
    bottomPadding: Style.space(4)
  }

  component FieldNote: Text {
    width: editor.width
    leftPadding: editor.inset
    rightPadding: editor.inset
    textFormat: Text.PlainText
    color: editor.dim
    font.family: editor.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  component FieldError: Text {
    property string message: ""
    visible: message !== ""
    width: editor.width
    leftPadding: editor.inset
    rightPadding: editor.inset
    bottomPadding: Style.space(4)
    textFormat: Text.PlainText
    text: message
    color: editor.urgent
    font.family: editor.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // A pick-one row: the options as a button group on the right. h/l and
  // Left/Right step through them, wrapping; Enter moves to the next one.
  component ChoiceRow: SettingRow {
    id: choiceRow
    property var choices: []
    property string value: ""
    readonly property bool keyboardEnabled: visible
    signal chosen(string choice)
    function keyboardActivate() { keyboardAdjust(1) }
    function keyboardAdjust(step) { chosen(editor.cycle(choices, value, step)) }
    foreground: editor.foreground
    fontFamily: editor.fontFamily
    hasCursor: editor.host.cursorItem === choiceRow
    onPointerEntered: editor.host.setCursor(choiceRow)

    ButtonGroup {
      options: choiceRow.choices
      value: choiceRow.value
      focusable: false
      foreground: editor.foreground
      fontFamily: editor.fontFamily
      fontSize: Style.font.caption
      onHovered: function(_index, on) { if (on) choiceRow.pointerEntered() }
      onChanged: function(choice) { choiceRow.chosen(choice) }
    }
  }

  // An on/off row with the switch on the right; a click, Enter or Space
  // flips it, and h/l turn it off and on.
  component SwitchRow: SettingRow {
    id: switchRow
    property bool checked: false
    readonly property bool keyboardEnabled: visible
    signal toggled()
    function keyboardActivate() { toggled() }
    function keyboardAdjust(direction) { if (checked !== (direction > 0)) toggled() }
    foreground: editor.foreground
    fontFamily: editor.fontFamily
    hasCursor: editor.host.cursorItem === switchRow
    onPointerEntered: editor.host.setCursor(switchRow)
    onClicked: toggled()

    ToggleSwitch {
      interactive: false
      checked: switchRow.checked
      foreground: editor.foreground
    }
  }

  // One of the rule's on/off flags.
  component FlagRow: SwitchRow {
    property string key: ""
    checked: editor.current[key] === true
    onToggled: {
      var name = key
      editor.change(function(next) { next[name] = !next[name] })
    }
  }

  // A dropdown row: Enter or a click opens the list, and h/l and Left/Right
  // step through its options, wrapping. `current` is the value it shows and
  // chosen() hands on a choice. The kit sets `value` itself on a choice,
  // which ends its binding, so the binding to `current` is restored.
  component DropdownRow: SettingRow {
    id: dropRow
    property var options: []
    property string current: ""
    readonly property bool popupOpen: drop.popupOpen
    readonly property bool keyboardEnabled: visible
    signal chosen(string choice)
    function keyboardActivate() { drop.open() }
    function keyboardAdjust(step) { if (options.length > 0) chosen(editor.cycle(options, current, step)) }
    foreground: editor.foreground
    fontFamily: editor.fontFamily
    hasCursor: editor.host.cursorItem === dropRow
    onPointerEntered: editor.host.setCursor(dropRow)
    onClicked: keyboardActivate()

    Dropdown {
      id: drop
      width: Style.space(170)
      showLabel: false
      options: dropRow.options
      value: dropRow.current
      foreground: editor.foreground
      fontFamily: editor.fontFamily
      onHovered: function(on) { if (on) dropRow.pointerEntered() }
      onChanged: function(choice) {
        dropRow.chosen(choice)
        drop.value = Qt.binding(function() { return dropRow.current })
      }
      onPopupOpenChanged: if (!popupOpen) editor.leaveInput()
    }
  }

  component EditorStepper: StepperRow {
    id: stepper
    foreground: editor.foreground
    fontFamily: editor.fontFamily
    hasCursor: editor.host.cursorItem === stepper
    onPointerEntered: editor.host.setCursor(stepper)
    onLeaveInput: editor.leaveInput()
  }
}
