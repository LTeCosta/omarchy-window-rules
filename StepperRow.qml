import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A whole-number setting: title and description, then − value + on the
// right, with an optional unit after the value. h/l (Left/Right) and the
// buttons step it by `step` within from..to; Enter, or a click on the value,
// starts typing, and Enter there or leaving the field commits the number.
SettingRow {
  id: row

  property int value: 0
  property int from: 0
  property int to: 100
  property int step: 1
  property string unit: ""
  readonly property bool editing: input.activeFocus
  readonly property bool keyboardEnabled: visible && enabled

  signal modified(int value)
  signal leaveInput()

  function clamp(number) { return Math.max(from, Math.min(to, Math.round(number))) }
  function keyboardActivate() { input.forceActiveFocus(); input.selectAll() }
  function keyboardAdjust(direction) { row.modified(clamp(value + direction * step)) }

  function commit() {
    var typed = parseInt(input.text, 10)
    if (!isNaN(typed) && clamp(typed) !== value) row.modified(clamp(typed))
    input.text = Qt.binding(function() { return String(row.value) })
  }

  onClicked: keyboardActivate()

  PanelActionButton {
    iconText: "󰍴"
    enabled: row.enabled && row.value > row.from
    foreground: row.foreground
    fontFamily: row.fontFamily
    onHovered: function(on) { if (on) row.pointerEntered() }
    onClicked: row.keyboardAdjust(-1)
  }

  BorderSurface {
    id: box
    readonly property var spec: Border.controlSpec(row.editing ? "focus" : "normal", row.foreground, Commons.Color.accent)
    width: Style.space(78)
    height: Style.space(22)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    radius: Style.cornerRadius
    color: row.editing ? Style.focusFillFor(row.foreground, Commons.Color.accent) : "transparent"
    borderSpec: row.editing ? spec : Border.none()

    Row {
      anchors.centerIn: parent
      spacing: Style.space(3)

      TextInput {
        id: input
        anchors.verticalCenter: parent.verticalCenter
        text: String(row.value)
        color: row.foreground
        selectionColor: Style.selectionFillFor(row.foreground, Commons.Color.accent)
        selectedTextColor: row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        horizontalAlignment: TextInput.AlignHCenter
        maximumLength: 5
        validator: RegularExpressionValidator { regularExpression: /[0-9]{0,5}/ }
        inputMethodHints: Qt.ImhDigitsOnly
        onEditingFinished: row.commit()
        onAccepted: row.leaveInput()
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: row.unit !== ""
        text: row.unit
        color: row.dim
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  PanelActionButton {
    iconText: "󰐕"
    enabled: row.enabled && row.value < row.to
    foreground: row.foreground
    fontFamily: row.fontFamily
    onHovered: function(on) { if (on) row.pointerEntered() }
    onClicked: row.keyboardAdjust(1)
  }
}
