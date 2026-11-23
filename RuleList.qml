import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The rule list: the summary strip, what the last save and the loader
// reported, and the RULES section with one row per rule in registration
// order (the last matching rule wins). Rows only ask; the panel changes its
// draft. A row that the schema refuses opens in the editor to be repaired.
// The panel's footer holds the capture, pick and new-rule actions; the
// window picker's list drops down from the RULES header.
Column {
  id: list

  required property var host
  required property var strings
  required property var store
  property var rows: []
  // Model.summaryCounts for the strip.
  property var summary: ({ total: 0, enabled: 0, dynamic: 0, moved: null, errors: 0 })
  property bool loaderMissing: false
  property string noticeText: ""
  property string errorText: ""

  readonly property color foreground: host.foreground
  readonly property color urgent: host.urgent
  readonly property color dim: host.dim
  readonly property string fontFamily: host.fontFamily
  readonly property bool inputActive: picker.popupOpen
  // Loader errors that name no rule, as { key, detail }; the others show on their row.
  readonly property var loaderErrors: store.loader.loaded === true ? Model.globalErrors(store.loader.errors) : []
  // A file holds at most Model.MAX_RULES rules.
  readonly property bool full: rows.length >= Model.MAX_RULES
  readonly property string fullText: format("list.full", [Model.MAX_RULES])

  signal editRequested(int index)
  signal moveRequested(int index, int delta)
  signal enableRequested(int index, bool enabled)
  signal duplicateRequested(int index)
  signal deleteRequested(int index)
  signal windowPicked(var client, var monitors)
  signal leaveInput()

  // A catalog string with its %1, %2... filled from untrusted arguments.
  function format(key, args) { return Model.fill(strings.t(key), args) }

  // One loader error ({ key, detail }) as a line of text.
  function errorLine(error) {
    return error.detail !== "" ? format("loader.errorLine", [strings.t(error.key), error.detail]) : strings.t(error.key)
  }

  function number(value) { return Commons.I18n.formatNumber(value) }

  function openPicker() { picker.open() }

  spacing: Style.space(8)

  // ---------- Summary ----------
  Row {
    id: tiles
    width: parent.width
    spacing: Style.space(6)
    readonly property real tileWidth: (width - spacing * 3) / 4

    StatTile {
      width: tiles.tileWidth
      value: list.format("summary.rules.value", [list.number(list.summary.enabled), list.number(list.summary.total)])
      label: list.strings.t("summary.rules")
      tooltipText: list.strings.t("summary.rules.hint")
      foreground: list.foreground
      fontFamily: list.fontFamily
    }

    StatTile {
      width: tiles.tileWidth
      value: list.number(list.summary.dynamic)
      label: list.strings.t("summary.dynamic")
      tooltipText: list.strings.t("summary.dynamic.hint")
      foreground: list.foreground
      fontFamily: list.fontFamily
    }

    StatTile {
      width: tiles.tileWidth
      value: list.summary.moved === null ? "—" : list.number(list.summary.moved)
      label: list.strings.t("summary.moved")
      tooltipText: list.strings.t("summary.moved.hint")
      foreground: list.foreground
      fontFamily: list.fontFamily
    }

    StatTile {
      width: tiles.tileWidth
      value: list.number(list.summary.errors)
      label: list.strings.t("summary.errors")
      tooltipText: list.strings.t("summary.errors.hint")
      alert: list.summary.errors > 0
      alertColor: list.urgent
      foreground: list.foreground
      fontFamily: list.fontFamily
    }
  }

  // ---------- Status ----------
  StatusLine {
    text: list.errorText !== "" ? list.errorText : list.noticeText
    color: list.errorText !== "" ? list.urgent : list.dim
  }

  StatusLine {
    text: list.store.lastError !== "" ? list.format(list.store.lastError, [list.store.lastErrorDetail]) : ""
  }

  StatusLine { text: list.loaderMissing ? list.strings.t("state.noLoader.title") : "" }

  Repeater {
    model: list.store.notes
    delegate: StatusLine {
      required property var modelData
      text: list.format(modelData.key, modelData.args)
    }
  }

  // Loader errors that name no rule; the others mark their row.
  Column {
    visible: list.loaderErrors.length > 0
    width: parent.width
    spacing: Style.space(4)

    SectionHeader {
      gap: 0
      text: list.strings.t("section.loader")
      meta: list.strings.tn("loader.errors", list.loaderErrors.length).arg(list.number(list.loaderErrors.length))
      metaColor: list.urgent
      foreground: list.foreground
      fontFamily: list.fontFamily
    }

    Repeater {
      model: list.loaderErrors
      delegate: StatusLine {
        required property var modelData
        font.pixelSize: Style.font.caption
        text: list.errorLine(modelData)
      }
    }
  }

  Column {
    visible: list.store.configErrors.length > 0
    width: parent.width
    spacing: Style.space(4)

    SectionHeader {
      gap: 0
      text: list.strings.t("loader.configErrors")
      meta: list.number(list.store.configErrors.length)
      metaColor: list.urgent
      foreground: list.foreground
      fontFamily: list.fontFamily
    }

    Repeater {
      model: list.store.configErrors
      delegate: StatusLine {
        required property var modelData
        font.pixelSize: Style.font.caption
        wrapMode: Text.WrapAnywhere
        text: modelData
      }
    }
  }

  // ---------- Rules ----------
  Column {
    width: parent.width
    spacing: Style.space(2)

    SectionHeader {
      id: rulesHeader
      text: list.strings.t("section.rules")
      meta: list.strings.t("section.rules.meta")
      foreground: list.foreground
      fontFamily: list.fontFamily

      // Capture of any open window. It has no trigger of its own (the
      // footer's Pick window opens it), so its list drops down over the rules.
      WindowPicker {
        id: picker
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.bottom
        store: list.store
        strings: list.strings
        foreground: list.foreground
        fontFamily: list.fontFamily
        onPicked: function(client, monitors) { list.windowPicked(client, monitors) }
        onPopupOpenChanged: if (!popupOpen) list.leaveInput()
      }
    }

    Repeater {
      model: list.rows

      delegate: RuleRow {
        id: ruleRow
        required property var modelData
        width: list.width
        row: modelData
        first: modelData.index === 0
        last: modelData.index === list.rows.length - 1
        hasCursor: list.host.cursorItem === ruleRow
        onPointerEntered: list.host.setCursor(ruleRow)
      }
    }

    Text {
      visible: list.rows.length === 0
      width: parent.width
      topPadding: Style.space(10)
      bottomPadding: Style.space(10)
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: list.strings.t("state.empty")
      color: list.dim
      font.family: list.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  // A line of status text, shown only when it has some; urgent unless set.
  component StatusLine: Text {
    visible: text !== ""
    width: list.width
    textFormat: Text.PlainText
    color: list.urgent
    font.family: list.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  // A compact pill on the right of a row: a target ("ws 1") or "off".
  // `tooltipText` gives the long form on hover.
  component Badge: BorderSurface {
    id: badge
    property string text: ""
    property string tooltipText: ""
    property real maxWidth: Style.space(150)
    implicitWidth: Math.min(badgeText.implicitWidth, maxWidth) + Style.space(10)
    implicitHeight: badgeText.implicitHeight + Style.space(4)
    color: "transparent"
    borderSpec: Border.controlSpec("normal", list.foreground, Commons.Color.accent)
    radius: Style.cornerRadius

    Text {
      id: badgeText
      anchors.centerIn: parent
      width: Math.min(implicitWidth, badge.maxWidth)
      textFormat: Text.PlainText
      text: badge.text
      color: list.dim
      font.family: list.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      elide: Text.ElideRight
    }

    HoverHandler { id: badgeHover }
    PanelToolTip {
      visible: badge.tooltipText !== "" && badgeHover.hovered
      text: badge.tooltipText
      fontFamily: list.fontFamily
    }
  }

  // One of a row's icon actions, shown under the cursor. Hovering it keeps
  // the cursor on `row`. While `available` is false it is disabled and shows
  // `unavailableText`, when set, on hover.
  component RowAction: Item {
    id: rowAction
    property Item row: null
    property string iconText: ""
    property string tooltipText: ""
    property bool available: true
    property string unavailableText: ""
    property color hoverColor: list.foreground
    signal activated()
    implicitWidth: icon.implicitWidth
    implicitHeight: icon.implicitHeight

    PanelActionButton {
      id: icon
      anchors.fill: parent
      enabled: rowAction.available
      iconText: rowAction.iconText
      tooltipText: rowAction.tooltipText
      foreground: list.foreground
      hoverColor: rowAction.hoverColor
      fontFamily: list.fontFamily
      fontSize: Style.font.bodySmall
      onHovered: function(on) { if (on && rowAction.row) rowAction.row.pointerEntered() }
      onClicked: rowAction.activated()
    }

    HoverHandler { id: actionHover }
    PanelToolTip {
      visible: !rowAction.available && rowAction.unavailableText !== "" && actionHover.hovered
      text: rowAction.unavailableText
    }
  }

  // One rule and a keyboard cursor stop: a glyph for its target, its name
  // over its apps or pattern, and its target badge on the right; under the
  // cursor the badge gives way to the row's actions. Enter or a click edits
  // it (a rule the schema refuses opens repaired), Space enables or disables
  // it. Names, apps, patterns, badges and loader errors come from a file or
  // another process, so every Text here is plain.
  component RuleRow: CursorSurface {
    id: rowItem

    property var row: ({})
    property bool first: false
    property bool last: false
    readonly property int ruleIndex: row.index
    readonly property bool keyboardEnabled: visible
    readonly property bool marked: !row.valid || row.loaderError
    readonly property real pad: Style.space(8)

    signal pointerEntered()

    function keyboardActivate() { list.editRequested(row.index) }
    function keyboardToggle() { list.enableRequested(row.index, !row.enabled) }

    foreground: list.foreground
    implicitHeight: column.implicitHeight + Style.space(12)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: rowItem.pointerEntered()
      onClicked: rowItem.keyboardActivate()
    }

    Text {
      id: glyph
      x: rowItem.pad
      width: Style.space(20)
      y: column.y + head.y + (head.height - height) / 2
      textFormat: Text.PlainText
      text: Model.targetGlyph(rowItem.row.target)
      color: rowItem.marked ? list.urgent : (rowItem.row.enabled ? list.foreground : list.dim)
      opacity: rowItem.row.enabled || rowItem.marked ? 1 : 0.6
      font.family: list.fontFamily
      font.pixelSize: Style.font.icon
    }

    Column {
      id: column
      anchors.left: glyph.right
      anchors.leftMargin: Style.space(6)
      anchors.right: parent.right
      anchors.rightMargin: rowItem.pad
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Item {
        id: head
        width: parent.width
        implicitHeight: Math.max(texts.implicitHeight, trailing.implicitHeight)

        Column {
          id: texts
          anchors.left: parent.left
          anchors.right: trailing.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: rowItem.row.name !== "" ? rowItem.row.name : rowItem.row.id
            color: rowItem.row.enabled ? list.foreground : list.dim
            font.family: list.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          // The apps the rule matches ("Code, T3 Code"), or its class pattern.
          Text {
            visible: text !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: rowItem.row.matchLabel
            color: list.dim
            opacity: rowItem.row.enabled ? 1 : 0.75
            font.family: list.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Item {
          id: trailing
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          implicitWidth: rowItem.hasCursor ? tools.implicitWidth : badges.implicitWidth
          implicitHeight: Math.max(tools.implicitHeight, badges.implicitHeight)
          width: implicitWidth
          height: implicitHeight

          Row {
            id: badges
            visible: !rowItem.hasCursor
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Badge {
              visible: !rowItem.row.enabled
              text: list.strings.t("badge.off")
              tooltipText: list.strings.t("list.disabled")
            }

            Badge {
              visible: rowItem.row.valid
              text: rowItem.row.badge ? list.format(rowItem.row.badge.key, rowItem.row.badge.args) : ""
              tooltipText: rowItem.row.summary ? list.format(rowItem.row.summary.key, rowItem.row.summary.args) : ""
            }
          }

          Row {
            id: tools
            visible: rowItem.hasCursor
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            RowAction {
              row: rowItem
              iconText: "󰏫"
              tooltipText: list.strings.t("action.edit")
              onActivated: list.editRequested(rowItem.row.index)
            }

            RowAction {
              row: rowItem
              available: !rowItem.first
              iconText: "󰁝"
              tooltipText: list.strings.t("action.moveUp")
              onActivated: list.moveRequested(rowItem.row.index, -1)
            }

            RowAction {
              row: rowItem
              available: !rowItem.last
              iconText: "󰁅"
              tooltipText: list.strings.t("action.moveDown")
              onActivated: list.moveRequested(rowItem.row.index, 1)
            }

            RowAction {
              row: rowItem
              iconText: rowItem.row.enabled ? "󰔡" : "󰨚"
              tooltipText: rowItem.row.enabled ? list.strings.t("action.disable") : list.strings.t("action.enable")
              onActivated: rowItem.keyboardToggle()
            }

            RowAction {
              row: rowItem
              available: !list.full
              unavailableText: list.fullText
              iconText: "󰆏"
              tooltipText: list.strings.t("action.duplicate")
              onActivated: list.duplicateRequested(rowItem.row.index)
            }

            RowAction {
              row: rowItem
              iconText: "󰅖"
              tooltipText: list.strings.t("action.delete")
              hoverColor: list.urgent
              onActivated: list.deleteRequested(rowItem.row.index)
            }
          }
        }
      }

      // Why a rule the schema refuses is not applied.
      Text {
        visible: !rowItem.row.valid
        width: parent.width
        textFormat: Text.PlainText
        text: rowItem.row.valid ? "" : list.format("list.invalid", [list.strings.t(rowItem.row.errorKey)])
        color: list.urgent
        font.family: list.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Repeater {
        model: rowItem.row.errors

        delegate: Text {
          required property var modelData
          width: column.width
          textFormat: Text.PlainText
          text: list.errorLine(modelData)
          color: list.urgent
          font.family: list.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
