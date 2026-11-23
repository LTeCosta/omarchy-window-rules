.pragma library
// State shared by every bar's instance of the panel. A .pragma library script
// has one copy per QML engine, so all instances see the same values.
//
// IPC reaches only the first instance that registered the target, which may
// sit on another monitor. That instance reads the focused window, leaves the
// capture here for the monitor that had the focus, and hands it to the
// instance whose bar is on that monitor, which opens if it is closed and
// takes the capture. No instance on another monitor takes it, open or not.

// How long a capture waits for a panel to take it.
var CAPTURE_TTL_MS = 5000

// { result, monitor, at } until it is taken or goes stale; null otherwise.
var pendingCapture = null

function matches(pending, monitorName, nowMs) {
  if (pending === null || nowMs - pending.at > CAPTURE_TTL_MS) return false
  return pending.monitor === "" || pending.monitor === String(monitorName || "")
}

// Leaves `result` (Model.ruleFromWindow's result, or null when nothing had
// focus) for the panel on `monitorName`, the monitor that had the focus
// ("" when it is not known: then the first panel to look takes it). A newer
// capture replaces one that is still waiting; one already taken is gone.
function putCapture(result, monitorName, nowMs) {
  pendingCapture = { result: result, monitor: String(monitorName || ""), at: nowMs }
}

// Whether a fresh capture is waiting for the panel on `monitorName`.
function hasCapture(monitorName, nowMs) {
  return matches(pendingCapture, monitorName, nowMs)
}

// The capture waiting for the panel on `monitorName`, as { result }, once;
// null when there is none for it. A capture for another monitor stays for
// its own panel; a stale one is dropped.
function takeCapture(monitorName, nowMs) {
  var pending = pendingCapture
  if (pending !== null && nowMs - pending.at > CAPTURE_TTL_MS) pendingCapture = null
  if (!matches(pending, monitorName, nowMs)) return null
  pendingCapture = null
  return { result: pending.result }
}

// The panel instances that are open, by an instance key, so state() can say
// whether the panel is open on any monitor.
var openPanels = {}

function setOpen(key, open) {
  if (open) openPanels[key] = true
  else delete openPanels[key]
}

function anyOpen() {
  for (var key in openPanels) return true
  return false
}
