import QtQuick
import qs.Ui
import "Model.js" as Model

// Capture of any open window: a searchable list of `hyprctl clients` that
// asks the store for a fresh list each time it opens. Choosing a window
// emits picked() with it and the displays, for Model.ruleFromWindow, which
// makes a rule that matches the window's app by its exact class. It shows no
// trigger of its own: the panel opens it with open() from its footer, and
// the list drops down from where the picker sits.
SearchableDropdown {
  id: picker

  required property var store
  required property var strings
  property var windows: ({ clients: [], monitors: [] })

  signal picked(var client, var monitors)

  showLabel: false
  // No trigger: zero height, and clipped so none of it shows; the list is a
  // popup, which the clip does not reach.
  rowHeight: 0
  clip: true
  value: ""
  triggerLabel: strings.t("action.pickWindow")
  placeholderText: strings.t("action.pickWindow.placeholder")
  emptyText: strings.t("action.pickWindow.empty")
  readonly property var clients: Model.arrayLike(windows.clients)

  // Class and title come from other applications; the kit draws them as plain text.
  options: clients.map(function(client, index) {
    return { value: String(index),
      label: client.title !== "" ? Model.fill(strings.t("picker.option"), [client["class"], client.title]) : client["class"] }
  })

  onPopupOpenChanged: {
    if (popupOpen) store.listWindows(function(result) { picker.windows = result })
  }

  onChanged: function(choice) {
    var client = clients[Number(choice)]
    // Model.ruleFromWindow reads both as the Qt lists they may become.
    var monitors = windows.monitors
    // Back to the trigger label for the next pick.
    Qt.callLater(function() { picker.value = "" })
    if (client) picked(client, monitors)
  }
}
