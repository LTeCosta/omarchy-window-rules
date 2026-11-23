# Window Rules

An [Omarchy](https://omarchy.org) bar widget and Hyprland Lua loader for deciding where and how windows open. Match one or more apps by exact window class (or write an RE2 regular expression for advanced cases), capture an open window's placement and state as a rule, list, edit and order your rules from the bar, and let Hyprland apply them directly on every reload — even when the shell is not running.

- Capture the focused window (from the panel or a key binding) or pick any open window to pre-fill a new rule matching its exact window class.
- Match windows by one or more exact app classes or an RE2 regular expression, optionally filter by exact or regex title, and optionally match the class and title the window opened with (`initial_class` / `initial_title`).
- Target a workspace number, a special workspace, a display slot on a specific monitor, or a custom Lua resolver.
- Control layout (**Tile** or **Float**), size, monitor-relative position or centering, display, fullscreen, maximize, pin, initial focus, focus (**Follow** or **Stay**), and opacity.
- Rules live in plain JSON in the plugin's state directory with an atomic writer lock, full-content conflict checks, and an automatic backup of the last valid file.

## Install

Verified with Omarchy `4.5.0-3`.

### 1. Install the plugin

From a published standalone plugin repository:

```bash
omarchy plugin add <plugin-repository-url>
omarchy plugin enable io.github.ltecosta.window-rules
```

Or from a checkout of this repository:

```bash
scripts/install window-rules
omarchy plugin enable io.github.ltecosta.window-rules
```

The widget's default place is the right side of the bar; move it with `omarchy bar move io.github.ltecosta.window-rules --section <section>`.

### 2. Add the loader block to Hyprland

Hyprland applies your rules through the plugin's Lua loader. Append this block at the **end** of `~/.config/hypr/hyprland.lua`:

```lua
do
  local home = os.getenv("HOME") or ""
  local config = os.getenv("XDG_CONFIG_HOME")
  if not config or config:sub(1, 1) ~= "/" then config = home .. "/.config" end
  local path = config .. "/omarchy/plugins/io.github.ltecosta.window-rules/hypr/window-rules.lua"
  local file = io.open(path, "r")
  if file then
    file:close()
    local ok, window_rules = pcall(dofile, path)
    if ok and type(window_rules) == "table" then
      -- window_rules.register_resolver(...)  -- optional, see "Resolvers"
      window_rules.load()
    end
  end
end
```

Place it at the end of the file, after Omarchy's defaults and any hand-written window rules: Hyprland evaluates window rules top to bottom and **the last matching rule wins**. The block handles a missing `HOME`, ignores a relative `XDG_CONFIG_HOME` (falling back to `$HOME/.config` per the XDG specification), does nothing when the plugin is absent (`io.open` returns `nil`), and guards `dofile` with `pcall` so a partial or broken install does not break Hyprland startup.

Reload Hyprland to activate the loader:

```bash
hyprctl reload
```

If you open the panel before adding the block, it displays the **SETUP** view (**The rule loader is not running**) with the same block and **Copy**, **Check again**, and **Back** footer buttons.

## Using the panel

Click the bar icon to open or close the panel. The icon highlights when the loader is not running, the rules file is invalid or from a newer version, or the loader has reported errors.

### Panel layout and fields

- **Hero**: shows the plugin icon, **Window Rules**, and a status line below it — `Reading the rules…` while loading, `Saving…` while writing, or `<N> rule(s) · <state>` once the loader state is known (`<state>` is the first match of `invalid file`, `newer file`, `loader not running`, `<N> error(s)`, or `loader OK`). In the list view, a trailing capture icon button (tooltip `Capture focused window`) sits on the right side of the hero.
- **Summary tiles** (list view, four tiles across the top):
  - **RULES** (`<enabled>/<total>`): enabled valid rules that apply, out of all rules in the file.
  - **DYNAMIC**: enabled valid rules targeting a **Display slot** or **Resolver**.
  - **MOVED**: windows the loader moved since Hyprland last reloaded (or `—` when the loader is not running).
  - **ERRORS**: total problems — invalid rules, rows with loader errors, global loader errors, and any file error (highlighted when greater than zero).
- **Status and error blocks** (shown when present): save notices or errors, reload/command failure notes, loader status notes (revision mismatch `loader.revisionMismatch`, loader version mismatch `loader.versionMismatch`, older loader format `loader.schemaOlder`, and newer loader API `loader.apiNewer`), a **LOADER** section (`<N> problem(s)`) for global loader errors, and **HYPRLAND CONFIGURATION ERRORS** for `hyprctl configerrors`.
- **RULES** section (right-side meta: `last match wins`): lists rules in registration order. Each compact row shows:
  - A target glyph on the left (distinct icons for special workspace, workspace number, display slot, resolver, anywhere, or alert for invalid rules).
  - The rule's **Name** (or `id` if empty) over its match summary (comma-separated app classes in **Apps** mode, or the class pattern in **Regex** mode, truncated to one line of at most 160 characters).
  - Right-side **badges** when the cursor is not on the row: an `off` badge (tooltip `Disabled`) when disabled, and a target badge (`anywhere`, `ws <id>`, `<special>`, `slot <n> · <display>`, or `<resolver> <arg>`) whose tooltip shows the full target summary.
  - Under the pointer or keyboard cursor, the badges give way to six row actions: **Edit**, **Move up**, **Move down**, **Enable** / **Disable**, **Duplicate**, and **Delete** (with confirmation).
  - Invalid rules display `Not applied: <reason>` below the row; per-rule loader errors appear below that.
- **Editor view**: opens with **Name** and an inline `id` (**Identifier**, used for Hyprland's rule name `window-rules/<id>` and tag `+window-rules:<id>`) at the top, followed by four sections of label-and-control rows and inline numeric steppers (`−` value `+`):
  - **MATCH** (right-side meta: `matches <N> window(s), approximately` or `no preview`): **Match by** (**Apps** / **Regex**), **Search open apps** multi-select and **Window class, such as org.example.App** + **Add** row (or **Window class, as a regular expression** in **Regex** mode), **Title** (**Off** / **Exact** / **Regex**) and title field, and **Opened with** (`match.initial`). See **Matching** below.
  - **PLACEMENT**: **Open on** dropdown (**Anywhere**, **Workspace**, **Special workspace**, **Display slot**, **Resolver**), target-specific fields (**Workspace** `1`–`9999`, **Name** for special workspace, **Display** + **Slot** `1`–`10`, or **Resolver** + argument stepper `1`–`99` labeled by the resolver's `arg_label` or **Argument**), and **Focus** (**Follow** / **Stay**, shown when **Open on** is not **Anywhere**).
  - **WINDOW**: **Layout** (**Default** / **Tile** / **Float**), **Set size** (**Width**, **Height** in `px`, `1`–`16384`), **Position** (**Default** / **Center** / **At** with monitor-relative **X**, **Y** in `px`, `0`–`16384`), and **Set display** (**Display**, chosen by description). Setting size or position when **Layout** is not **Float** shows a non-blocking warning (`Size and position only apply to floating windows`).
  - **STATE**: **Enabled**, **Fullscreen**, **Maximize** (cannot be enabled together with **Fullscreen**), **Pin to every workspace**, **No initial focus**, and **Set opacity** (**Opacity**, `5`–`100` `%`, stored as `0.05`–`1.0`).
  - Validation errors appear under the field they belong to, and **Save** stays disabled until the rule is valid (and the plugin's state directory is ready). Saving reloads Hyprland so rules apply to windows opened afterward; **saving does not move or restyle windows that are already open**.
- **Footer buttons** (pinned below the scrollable body, equal-width buttons per view):
  - **List (no pending changes)**: **Capture** (tooltip `Capture focused window`), **Pick window** (tooltip `Capture another window`), **New rule**.
  - **List (unsaved changes)** (above the buttons: `Unsaved changes to the list`): **Save** (shows `Saving…` while saving), **Discard**.
  - **Editor**: **Save** (shows `Saving…` while saving), **Cancel**.
  - **Setup** (**SETUP** / `one-time`): **Copy** (changes to **Copied**), **Check again**, **Back** (tooltip `Back to the list`).
  - **Conflict** (**CONFLICT** / `nothing written`): **Reapply my rule** and **Discard my rule** when a rule was open in the editor; otherwise **Back** (tooltip `Back to the list`).
  - **Invalid file** (**RULES FILE**): **Restore the last valid version** when a valid `rules.json.bak` exists; otherwise no footer.
  - **Unsupported file** (**RULES FILE**) and **Loading**: no footer.

### Shortcuts and IPC

```bash
omarchy-shell io.github.ltecosta.window-rules open     # open the panel on the focused monitor
omarchy-shell io.github.ltecosta.window-rules close    # close whichever panel is open
omarchy-shell io.github.ltecosta.window-rules toggle   # toggle the panel on the focused monitor
omarchy-shell io.github.ltecosta.window-rules capture  # capture the focused window on the focused monitor
omarchy-shell io.github.ltecosta.window-rules state    # JSON summary for scripts and checks
```

Each monitor's bar runs its own instance of the widget, while IPC reaches only the first instance that registered `io.github.ltecosta.window-rules`. To act on the monitor you are looking at, `open`, `toggle`, and `close` go through the shell via `omarchy-shell shell summon|toggle|hide io.github.ltecosta.window-rules`.

The `capture` IPC method reads the focused window (`hyprctl activewindow -j`) and monitors (`hyprctl monitors -j`) **before** opening any panel so the panel does not steal focus first, records the focused monitor, stores the capture in `Shared.js` (shared across all bar instances in the QML engine, with a 5-second TTL), delivers it directly to the panel instance on the monitor that had focus via `bar.moduleWidgets` (or falls back to `omarchy-shell shell summon` if none matched), and returns `"ok"`. Only the panel on the monitor that had focus takes the capture — open panels on other monitors ignore it. If that panel is already open it takes the capture immediately; otherwise it opens and takes it as it opens. Concurrent capture lookups are queued in the store (up to 4 pending); `Shared.js` holds the latest waiting handoff until taken or expired.

When a capture reaches a panel that is showing the **conflict**, **invalid file**, or **unsupported file** view (or while a save is running), the panel **refuses** the capture with a notice (`Reapply or discard your kept rule before capturing a window`, `The rules file cannot be changed until it is fixed or restored`, or `A save is already in progress`) without opening a hidden editor or mutating the draft. While the panel is still loading, an arriving capture is dropped. In an editable view, a captured window opens the editor pre-filled (asking **Replace the rule you are editing?** if an unsaved rule is already open); if nothing had focus, the panel shows `No focused window to capture`.

Example output of `state`:

```json
{"open":false,"fileState":"ok","revision":7,"rules":4,"loaderLoaded":true,"errors":0}
```

`open` is `true` when the panel is open on any monitor, and `fileState` is one of `"missing"`, `"ok"`, `"invalid"`, or `"unsupported"`. The panel queries `window_rules.describe()` and `hyprctl configerrors` at startup, when opened, after saves, on Hyprland's `configreloaded` event, and on outside changes to `rules.json`, so `state()` reflects those updates even before the panel is opened.

Recommended key bindings in `~/.config/hypr/bindings.lua` (or `~/.config/hypr/hyprland.lua`):

```lua
o.bind("SUPER + ALT + W", "Save window rule", "omarchy-shell io.github.ltecosta.window-rules capture")
o.bind("SUPER + SHIFT + ALT + W", "Window rules", { panel = "io.github.ltecosta.window-rules" })
```

Use `{ panel = "io.github.ltecosta.window-rules" }` for opening or toggling the panel directly through Omarchy's shell, and the `capture` IPC command for capturing the focused window before the panel opens.

### Capturing and creating rules

- **Capture** (`c` in the list, the hero capture button, or the `capture` IPC): reads the focused window's class, title, workspace, display, floating geometry, fullscreen/maximize state, and pin flag.
  - **Match by** is set to **Apps** with the window's exact class pre-selected.
  - **Title** starts **Off**, with the window's exact title ready if you switch it to **Exact** (or escaped as `^<escaped title>$` if you switch it to **Regex**).
  - **Open on** is set to **Special workspace** for a special workspace, **Display slot** (`desc:<description>` and slot `1–10`) for a regular workspace on a known display, or **Workspace** if the display is not reported.
  - Floating windows set **Layout** to **Float** and capture **Width**, **Height**, and monitor-relative **Position** (**At**, clamped into `0–16384` with warning `capture-position-clamped` if the window was partly off its display). Tiled windows leave **Layout** at **Default** with no size or position.
  - **Identifier** is derived as a unique lowercase slug from **Name** and updates as you edit **Name** until you edit **Identifier** directly.
- **Pick window**: drops down a searchable list of all open windows (`hyprctl clients -j`, shown as `class — title`) below the **RULES** header and pre-fills the editor from the one you pick.
- **New rule** (`n` in the list): opens a new rule in the editor in **Apps** mode with no name or app chosen yet (**Save** stays disabled until you enter a **Name** and choose or add at least one app, or switch to **Regex** and enter a pattern).

### Ordering, drafts, saving and conflicts

Rules are listed in registration order — **the last matching rule wins**. Moving the pointer or keyboard cursor over a row reveals its action buttons: **Edit**, **Move up**, **Move down**, **Enable** / **Disable**, **Duplicate**, and **Delete** (with confirmation).

List changes (reordering, enabling or disabling, duplicating, and deleting) accumulate in a pending draft (`Unsaved changes to the list`) instead of reloading Hyprland on every click. Click **Save** (or press `s`) to write `rules.json` and reload Hyprland, or **Discard** to revert. Saving from the editor saves the edited rule together with any pending list changes.

Your draft survives closing and reopening the panel until you save or discard it. Each monitor's bar keeps its own draft:

- **Edits held while a save runs**: while a save or restore is in flight, the list and editor are read-only — list edits, opening rules, new rules, duplication, deletion, editor changes, and captures are blocked or refused (`A save is already in progress`). Save completion checks the draft version it submitted and only clears that draft.
- **Writer lock and stale-lock takeover**: every save and backup restore takes an atomic lock directory (`rules.lock` in the state directory via `mkdir`) before re-reading `rules.json` and releases it (`rmdir`) after writing and setting `0600` permissions. If another bar holds a fresh lock (30 seconds old or newer), nothing is written and the panel shows `Another panel is saving the rules right now. Nothing was written; try again in a moment.`. If a lock is older than 30 seconds (abandoned), a competing bar atomically renames it (`mv -T`) to a unique temporary name so only one bar can claim it, checks its age again (moving it back if another bar took a fresh lock meanwhile), removes the stale lock, and retries once.
- **Conflicts and what is kept**: a draft stores the exact file content read when editing began. Before writing, the panel re-reads `rules.json` under `rules.lock` and compares its full content (not only `revision`). If the file changed on disk, nothing is written, the current file is loaded, pending list changes are cleared, and the panel shows **The rules changed elsewhere**. When you were editing a rule, the panel keeps your edited rule and offers **Reapply my rule** or **Discard my rule**: reapplying puts the rule back in place if its original entry in the reloaded file is unchanged, or appends it otherwise (picking a free identifier if another rule now uses its `id`). If appending would exceed the 200-rule limit, **Reapply my rule** refuses with `A rules file holds at most 200 rules; remove one first` and keeps the conflict view and your kept rule intact.
- **Delete and restore confirming against what was shown**:
  - **Delete** freezes the target rule's identity (index, `id`, canonical JSON, and name) when the confirmation dialog opens. Confirming deletes that exact rule even if the list was reordered meanwhile; if the rule changed or disappeared before confirmation, nothing is deleted and the panel shows `That rule changed or was removed meanwhile; nothing was deleted`.
  - **Restore the last valid version** freezes the file state shown when the dialog was offered. Under `rules.lock`, it verifies that `rules.json` has not changed since then (for example, repaired elsewhere); if it changed, nothing is restored and the panel shows `The rules file changed since it was shown; nothing was restored`.
- **Saved but not reloaded**: every shell command runs with a 10-second timeout. Once `rules.json` has been written, if `hyprctl reload` or `hyprctl repl` fails or times out, the file remains saved and the list displays `The rules were saved, but “<command>” failed, so Hyprland may not apply them yet` instead of `Saved and reloaded`.
- **Restore from backup**: if `rules.json` cannot be read or is invalid (including a zero-byte file, which is invalid JSON rather than a missing file), the panel shows **The rules file cannot be used** read-only and offers **Restore the last valid version** when a valid `rules.json.bak` exists.
- **Rule and app limits**:
  - A rules file holds at most **200 rules**. At 200 rules, **New rule** and **Duplicate** are disabled (tooltip `A rules file holds at most 200 rules; remove one to add another`), and keyboard, capture, or conflict-reapply attempts report `A rules file holds at most 200 rules; remove one first`.
  - An **Apps**-mode rule matches **1 to 32 window classes**. When a rule already has 32 apps, clicking **Add** (or pressing Enter) refuses a 33rd class, keeps the typed text in the field, and shows `A rule matches at most 32 apps; remove one to add another`.
- **Editing an invalid rule**: if a hand-edited `rules.json` contains a rule that fails rule-level validation, the list displays it as `Not applied: <reason>`. You can still reorder, enable/disable, duplicate, or delete it directly, or open it in the editor to repair it: opening an invalid rule keeps every valid field and unknown field, fills missing optional fields with their defaults, resets invalid fields to their defaults (marking each reset field with `Reset to its default: <reason>` and showing a notice banner at the top), and replaces the entry in `rules.json` when you save. Cancelling leaves the original entry unchanged.

### Keyboard

| Key | Action |
|---|---|
| `j` / `k`, Down / Up | Move the cursor between items (body rows/fields and footer buttons) |
| `h` / `l`, Left / Right | In the editor, cycle dropdowns (**Open on**, **Display**, **Resolver**) and choice rows (**Match by**, **Title**, **Focus**, **Layout**, **Position**) wrapping around the ends; turn switches off (`h` / Left) or on (`l` / Right); or step numbers (**Workspace**/**Slot**/**Argument** by 1; **Width**/**Height**/**X**/**Y** by 10; **Opacity** by 5) |
| Enter | Activate the focused item (edit a rule row, press a button, focus a text field or select a stepper's number for typing, open a dropdown or app multi-select, toggle a switch, or step a choice row); while typing in a text field or stepper, commits and returns focus to the panel (in the add-app field, also adds the typed class) |
| Space | On a rule row, enable or disable it; on other controls, activate like Enter |
| `Ctrl+j` / `Ctrl+k`, `Ctrl+Down` / `Ctrl+Up` | Move the selected rule down or up in the list |
| `d` | Duplicate the selected rule in the list (inserts a copy below it with a free identifier; disabled at 200 rules) |
| `x`, Delete | Delete the selected rule in the list (asks confirmation) |
| `n` | New rule (in the list; disabled at 200 rules) |
| `c` | Capture focused window (in the list) |
| `s` | Save pending list changes, or save the rule in the editor |
| Tab / Shift+Tab | Switch to the next or previous bar panel |
| Escape | Leave a text field or stepper, close a dropdown, picker, or confirmation dialog, or close the panel |

## Matching

### Apps mode (default)

Captures and new rules default to **Apps** mode (`match.mode: "apps"`), which matches 1 to 32 exact window classes:

- Pick open apps from the **Search open apps** multi-select (lists each open window's class once with its first window's title as description, followed by any classes already on the rule whose apps are not open).
- Add an app that is not currently open by typing its class into **Window class, such as org.example.App** and pressing Enter or clicking **Add**.
- Characters with special meaning in regular expressions (such as `.`, `+`, `(`, `)`) are kept literal — you do not need to escape them.

To find a window's exact class, capture the window from the panel or key binding, or run:

```bash
hyprctl clients -j | jq -r '.[].class'
```

### Regex mode (advanced)

Switch **Match by** to **Regex** (`match.mode: "regex"`) when you need a pattern rather than a list of exact classes (for example, `^(steam|steam_app_.+)$`). Switching from **Apps** to **Regex** without a previously stashed pattern pre-fills the compiled `^(...)$` pattern of your chosen apps so the rule keeps matching the same windows; switching back and forth restores what each mode held.

- **Full match**: Hyprland matches `class` and `title` with **RE2 full-match** (`RE2::FullMatch`): a pattern must match the whole string, not just a substring (for example, `^org\.example\.App$` or `steam|steam_app_.+`).
- **Refused constructs**: both `Model.js` and `hypr/schema.lua` refuse constructs that RE2 does not support (checked outside character classes `[...]`):
  - Lookahead and lookbehind: `(?=...)`, `(?!...)`, `(?<=...)`, `(?<!...)`
  - Backreferences: `\1`–`\9` and `\k<name>`
  - JavaScript-style named groups: `(?<name>...)` (use RE2's `(?P<name>...)` or a non-capturing group `(?:...)` instead)
- **Inline flags (`(?i)` etc.)**: leading RE2 flags `(?i)`, `(?m)`, and `(?s)` (and combinations such as `(?ims)`) are translated to JavaScript `RegExp` flags by the editor, so they compile and preview normally. Patterns that use the RE2 ungreedy flag `U` (such as `(?U)`) or a flag group anywhere after the start (such as `a(?i)b`, `(?i:a)`, `(?-i)a`, or `(?i)(?s)a`) are **allowed**: the editor shows the non-blocking warning `warn-pattern-unchecked` and displays `no preview` instead of blocking **Save**.
- **`negative:` prefix**: Hyprland's `negative:` prefix matches windows that do **not** match the remainder of the pattern. The editor validates the remainder after `negative:`, previews the inverted match count, and shows the non-blocking warning `warn-pattern-negative`.
- **Editor syntax check and approximate preview**: Lua has no regex engine, so `hypr/schema.lua` checks only length, control characters, and refused constructs. The panel editor additionally compiles regex patterns with JavaScript `RegExp` (`Model.checkPattern`) and reports `pattern-syntax` if compilation fails (for example, an unclosed `(` or `[`). `pattern-syntax` disables **Save** when the pattern is new or edited, but does not block saving an unchanged hand-edited pattern when you edit other fields of that rule. The open-window match count tests at most 512 open windows and the first 512 UTF-16 units of each class and title, and is labeled approximate because JS `RegExp` and RE2 differ in details such as Unicode character classes.

### Title matching and Opened with

- **Title**: choose **Off** (empty title, matches every title), **Exact** (`titleMode: "exact"`, matches the exact window title literally with regex characters escaped automatically), or **Regex** (`titleMode: "regex"`, full-match RE2 pattern with the same checks as regex class matching). Captured windows start with **Title** **Off** and keep the window's title ready if you turn **Exact** or **Regex** on.
- **Opened with** (`match.initial: true`): matches the class and title the window opened with (`initial_class` and `initial_title` in Hyprland, `initialClass` and `initialTitle` in the editor preview) instead of its live `class` and `title`. Use this for applications that change their class or title after the window is created.

### How a match compiles

Both `Model.compileMatch` and `hypr/schema.lua`'s `compile_match` translate a valid `match` into the table passed to Hyprland's `o.window(match, effects)` identically (verified by `compileCases` in `tests/fixtures/conformance.json`):

- **Escaping rule**: for exact app classes and exact titles, every ASCII character other than a letter (`A-Z`, `a-z`), a digit (`0-9`), or `_` is escaped with a leading `\`; non-ASCII characters are copied as-is.
- **Apps mode**: joins escaped classes as `^(<c1>|<c2>|...)$` (a single class becomes `^(<c1>)$`).
- **Regex mode** (or omitted `mode`): passes `match.class` through unchanged.
- **Title**: omitted when `match.title` is empty (`""`); compiled to `^<escaped title>$` when `titleMode` is `"exact"`, or passed through unchanged when `titleMode` is `"regex"` (or omitted).
- **Opened with**: when `match.initial` is `true`, emits `initial_class` (and `initial_title` if title is non-empty) instead of `class` (and `title`).

Examples:

| `match` in `rules.json` | Compiled Hyprland match |
|---|---|
| `{"mode":"apps","classes":["com.microsoft.VSCode","com.t3tools.T3Code"]}` | `{"class":"^(com\\.microsoft\\.VSCode|com\\.t3tools\\.T3Code)$"}` |
| `{"mode":"apps","classes":["teams-for-linux"]}` | `{"class":"^(teams\\-for\\-linux)$"}` |
| `{"mode":"apps","classes":["a+b (x)_é"]}` | `{"class":"^(a\\+b\\ \\(x\\)_é)$"}` |
| `{"mode":"apps","classes":["a"],"title":"Steam - News","titleMode":"exact"}` | `{"class":"^(a)$","title":"^Steam\\ \\-\\ News$"}` |
| `{"mode":"apps","classes":["a"],"title":"T","titleMode":"exact","initial":true}` | `{"initial_class":"^(a)$","initial_title":"^T$"}` |
| `{"mode":"regex","class":"^(steam|steam_app_.+)$"}` | `{"class":"^(steam|steam_app_.+)$"}` |

## Targets and precedence

**Open on** chooses how a rule places a window:

- **Anywhere** (`none`): leaves workspace placement alone and applies only the rule's other effects.
- **Workspace** (`id`, `1`–`9999`): static Hyprland rule sending the window to that exact workspace number.
- **Special workspace** (`special`, name `1`–`32` characters from `A-Z`, `a-z`, `0-9`, `_`, `-`): static Hyprland rule sending the window to `special:<name>`.
- **Display slot** (`monitor-slot`): dynamic target naming a physical display by its EDID description (`desc:<description>`, stable across dock connector renames) and a slot `1`–`10`. Omarchy gives each physical monitor its own block of workspaces (10 by default, for example 1–10 on the built-in panel and 11–20 on the next monitor), and the loader asks `o.workspaces.workspace_id(monitor, slot)` for the live workspace number when a window opens. If that display is disconnected, the target declines quietly and no error is recorded. If the target workspace does not exist yet, the loader creates and reclaims it through `o.workspaces.focus(slot, monitor.name)`; if it already exists on another display, it moves the workspace onto the target display.
- **Resolver** (`resolver`): dynamic target calling a custom Lua function registered in `~/.config/hypr/hyprland.lua` with an integer argument `1`–`99`.

### Precedence and candidate walk

Every enabled valid rule registers through `o.window` (guarded with `pcall` per rule) in `rules.json` array order with `name = "window-rules/<id>"` and `tag = "+window-rules:<id>"`.

- When dynamic capabilities are present, each dynamic rule (`monitor-slot` or `resolver`) also emits `workspace = "unset"`. This cancels `workspace` from earlier static rules in `rules.json` — and **also cancels `workspace` from earlier rules written by hand outside the plugin** (those rules do not carry a plugin tag, so no fallback recovers them).
- On `window.open`, the loader collects all registered rules whose `window-rules:<id>` tag is present on the window and walks them in **reverse array order** (last rule in `rules.json` first):
  - Rules with target `none` (and dynamic rules when dynamic capabilities are missing) are skipped for workspace selection.
  - A **dynamic** rule (`monitor-slot` or `resolver`) attempts to resolve its target:
    - If it resolves, it wins and the walk stops.
    - If it **declines quietly** (for example, a `monitor-slot` display is disconnected or a resolver returns `nil`), the walk continues to earlier candidates.
    - If a resolver is **missing or fails** (`resolver-missing` or `resolver-failed`), the error is recorded and **the walk continues** to earlier candidates rather than stopping.
  - A **static** rule (`id` or `special`) **ends the walk**:
    - If no later dynamic rule ran before it, Hyprland has already applied it (suppressing any earlier dynamic rule).
    - If a later dynamic rule declined, failed, or had a missing resolver (having set `workspace = "unset"`), the loader applies that earlier static target itself in `window.open` with **static semantics** — honoring its `follow` setting directly, **without** the sibling filter, reapplying effective position, and counting the move.
- **Position** is resolved independently of the workspace target: the effective position is taken from the **last** matching tagged rule whose `position.type` is not `"none"`. After a loader move, if the window is floating (`window.floating ~= false`), the loader reapplies **Center** (via `hl.dsp.window.center`, when available) or **At** (adding the destination monitor's `x` and `y` origin via `hl.dsp.window.move`).

Rules apply only to windows opened after Hyprland loads them; saving changes or reloading Hyprland does not move windows that are already open.

### Focus and later windows

- **Static targets** (**Workspace**, **Special workspace**): **Follow** (`follow: true`) switches to the target workspace; **Stay** (`follow: false`) appends `silent` to Hyprland's workspace rule (`"<id> silent"` or `"special:<name> silent"`). The sibling rule below does **not** apply to static targets, including when the loader falls back to an earlier static rule after a dynamic rule declines or fails.
- **Dynamic targets** (**Display slot**, **Resolver**):
  - If the window is already on the target workspace, nothing happens.
  - **Sibling rule (dynamic targets only)**: the loader checks for other open windows with both the same `pid` and the same `class`:
    - If **no sibling** is open (the first window of that process and class), the window moves using the rule's `follow` setting. Separate web apps sharing one browser process have distinct `class` values, so each web app's first window still follows when `follow: true`.
    - If a **sibling is open** and **none is on the target workspace**, the new window stays where it opened rather than being pulled away from its running app.
    - If a **sibling is open** and **one is already on the target workspace**, the new window moves **silently** (even when `follow: true`), so dialogs, menus, and toasts do not steal focus.
  - **Silent moves (`follow: false` or later sibling)**: when creating a missing target workspace pulled Hyprland onto it, the loader first returns the destination monitor (or the origin monitor when the target names none) to the regular workspace it was showing before — so every monitor keeps the regular workspace it showed, whether on another monitor or underneath an open special workspace on the same monitor. It then restores focus to the previously focused window on a **visible** workspace (using `focus_history_id` when Hyprland has already focused the new window, and including an open special workspace such as a drop-down console by focusing its monitor first — never focusing a window on a hidden special workspace, which would open it), or back to the previous monitor and regular workspace when no visible window had focus.

## Resolvers

Register resolvers in `~/.config/hypr/hyprland.lua` inside the loader block, after `pcall(dofile, path)` and before `window_rules.load()`:

```lua
window_rules.register_resolver(name, {
  label = "Human-readable name", -- optional; defaults to name
  arg_label = "Slot",            -- optional; editor label for the 1-99 argument (default "Argument")
  resolve = function(arg, window)
    return { workspace = workspace_id, monitor = monitor_name }
  end,
})
```

Contract:

- `name` must be 1–32 characters matching `^[a-z0-9-]+$`. Registering the same name again replaces it. `register_resolver` returns `true` on success and `false` on invalid arguments without raising.
- `resolve(arg, window)` receives the rule's integer `arg` (`1`–`99`) and Hyprland's `HL.Window` userdata object (read its fields such as `window.class`, `window.title`, `window.address`, `window.pid`, `window.workspace`).
- `resolve` returns `{ workspace = <integer >= 1>, monitor = <connector name or nil> }`, or **`nil` to decline quietly** (no destination right now, such as a missing display or out-of-range slot): no error is recorded and the candidate walk continues to any earlier tagged rule with a target. Raising an error or returning anything else records `resolver-failed` and continues the candidate walk to earlier candidates (leaving the window in place if no earlier candidate applies).
- When `monitor` is provided, the loader moves an existing workspace onto that monitor if needed, or focuses that monitor before creating a missing workspace.

Example targeting a slot on the first non-mirrored external monitor (checking slot bounds and falling back to the built-in display or active monitor when unplugged):

```lua
local function is_internal(monitor)
  return monitor.name:match("^eDP")
    or monitor.name:match("^LVDS")
    or monitor.name:match("^DSI")
end

window_rules.register_resolver("external-slot", {
  label = "External display slot",
  arg_label = "Slot",
  resolve = function(slot, _window)
    local max_slots = (o and o.workspaces and o.workspaces.slots) or 10
    if type(slot) ~= "number" or math.tointeger(slot) == nil or slot < 1 or slot > max_slots then
      return nil
    end

    local external = nil
    local fallback = nil

    for _, monitor in ipairs(hl.get_monitors()) do
      if not monitor.is_mirror then
        if not is_internal(monitor) and not external then
          external = monitor
        elseif not fallback then
          fallback = monitor
        end
      end
    end

    local target = external or fallback or hl.get_active_monitor()
    if target then
      return {
        workspace = o.workspaces.workspace_id(target, slot),
        monitor = target.name,
      }
    end
    return { workspace = slot }
  end,
})
```

See [examples/hyprland.lua](examples/hyprland.lua) for a complete, commented loader block ready to copy into `~/.config/hypr/hyprland.lua`.

## Lua API

Loading `hypr/window-rules.lua` with `dofile(path)` returns the loader module table and also assigns it to the global `window_rules` so `hyprctl repl` can inspect it.

- **`api_version`** (integer, currently `1`): major version of the Lua API contract, following semantic versioning — backward-compatible additions keep the same `api_version`, and breaking changes increment it.
- **`required_api`** (array of strings): the 14 Hyprland/Omarchy Lua paths required for dynamic targets (`o.workspaces.workspace_id`, `o.workspaces.focus`, `hl.on`, `hl.dispatch`, `hl.dsp.focus`, `hl.dsp.window.move`, `hl.dsp.workspace.move`, `hl.get_workspace`, `hl.get_monitor`, `hl.get_windows`, `hl.get_window`, `hl.get_active_window`, `hl.get_active_monitor`, `hl.get_active_workspace`). Static rule registration additionally requires `o.window`.
- **`required_fields`** (table): field lists read by the dynamic handler on `HL.Window`, `HL.Monitor`, and `HL.Workspace`, checked against Hyprland's Lua stubs by `tests/contract_test.lua`.
- **`register_resolver(name, spec)`**: registers or replaces a resolver; returns `true` on success and `false` on invalid arguments without raising.
- **`load([path])`**: removes any previous `window.open` subscription, resets loader state and counters, reads `path` (defaulting to `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/io.github.ltecosta.window-rules/rules.json`, ignoring a relative `XDG_STATE_HOME`), falls back to `<path>.bak` if the primary file fails reading or validation (recording `using-backup`), checks static and dynamic capabilities, registers each enabled valid rule inside `pcall(o.window, schema.compile_match(rule.match), effects)` (recording `register-failed` and continuing if Hyprland refuses a rule), and subscribes to `hl.on("window.open", ...)` when dynamic capabilities are present and at least one enabled dynamic rule is registered. Returns `true` when the file is missing or loaded (including via backup), and `false` if loading failed without a valid backup, `o.window` is missing, or an unexpected error was caught (`handler-failed`).
- **`describe()`**: returns a deterministic JSON string describing the current loader state (never raises). Fields:
  - `loaded` (boolean): `true`
  - `api` (integer): `api_version`
  - `loaderVersion` (string): version from `manifest.json` (or `"unknown"`)
  - `schema` (integer): `1`
  - `revision` (integer): loaded document revision (`0` when missing or omitted)
  - `rules` (integer): count of enabled valid rules registered via `o.window`
  - `dynamic` (integer): count of registered rules with active dynamic targets
  - `counters` (object): `{ "opened": <int>, "matched": <int>, "moved": <int> }` — windows seen by `window.open`, windows with any `window-rules:<id>` tag, and windows moved by the loader (dynamic targets and static fallbacks); all three remain `0` when `dynamic` is `0` because `window.open` is only subscribed when at least one enabled dynamic rule is registered
  - `resolvers` (array, sorted by `name`): `{ "name", "label", "argLabel" }`
  - `errors` (array, deduplicated per `(id, index, code)`, capped at 200): `{ "id": <string|null>, "index": <1-based int|null>, "code": <string>, "detail": <string> }`
- **`move_window(address, target, follow)`**: moves window `address` (without an `"address:"` prefix) to `target` (`{ workspace = <integer >= 1>, monitor = <connector name or nil>, slot = <integer >= 1 or nil> }`), following focus unless `follow == false`, using the same workspace-creation, monitor-reclaim, and silent focus-restoration logic as dynamic rules. Checks `required_api` first (recording `capability-missing` if unavailable). Returns `true` on success, `false` on invalid arguments, missing capabilities, or a caught error (`handler-failed`).

## Files and format

Rules are stored at:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/io.github.ltecosta.window-rules/rules.json
```

(A relative `XDG_STATE_HOME` is ignored and falls back to `$HOME/.local/state`, in both the panel and the Lua loader.)

- The state directory is created with mode `0700` (and existing directories are tightened to `0700`); `rules.json` and `rules.json.bak` are written atomically and set to mode `0600`.
- Each save from the panel takes `rules.lock`, re-reads `rules.json`, checks that its content matches the draft's base text, validates the resulting document (at most 200 rules, safe integer revision, at most 1 MiB UTF-8, valid strict JSON), saves the previous valid file to `rules.json.bak`, writes the new file with `revision + 1`, and releases the lock before reloading Hyprland.
- If `rules.json` becomes unreadable or invalid (including a zero-byte file), Hyprland's loader falls back to a valid `rules.json.bak` with `using-backup`, while the panel shows the file read-only and offers **Restore the last valid version**. A file with `version` greater than `1` is shown read-only until the plugin is updated.
- Hand-editing `rules.json` is supported: the panel watches the file for changes (and refreshes the loader state when it changes outside this bar), preserves unknown top-level, per-rule, and per-match keys when saving, and passes untouched invalid rules through unchanged. Run `hyprctl reload` after hand edits so Hyprland loads them.

### Schema v1

File limits: valid RFC 8259 JSON without a UTF-8 BOM, at most 1 MiB (1,048,576 bytes), nesting depth at most 64, and at most 200 rules. String lengths are counted in Unicode code points, and control characters (`U+0000`–`U+001F`, `U+007F`) and invalid UTF-8 / lone surrogates are refused.

| Field | Type and limits | Default | Hyprland effect |
|---|---|---|---|
| `version` | integer `1` | required | — |
| `revision` | integer `0`–`9007199254740991` (`2^53 - 1`) | `0` | — |
| `rules` | array, ≤ 200 rules | required | registered in array order |
| `id` | `^[a-z0-9][a-z0-9-]{0,47}$`, unique | required | `name = "window-rules/<id>"`, `tag = "+window-rules:<id>"` |
| `name` | string, 1–80 code points | required | — |
| `enabled` | boolean | `true` | disabled rules are not registered |
| `match.mode` | `"apps"` or `"regex"` | `"regex"` | selects `classes` (compiled to `^(c1\|c2)$`) vs. `class` (passed through) |
| `match.classes` | array of 1–32 strings, each 1–256 code points (literal) | required when `mode` is `"apps"` | `class` or `initial_class` as `^(<escaped>\|...)$` |
| `match.class` | RE2 regex string, 1–256 code points | required when `mode` is `"regex"` | `class` or `initial_class` as written |
| `match.title` | string, 0–256 code points | `""` | `title` or `initial_title` (omitted when empty) |
| `match.titleMode` | `"exact"` or `"regex"` | `"regex"` | `"exact"` compiles to `^<escaped>$`; `"regex"` passes through |
| `match.initial` | boolean | `false` | `true` emits `initial_class` / `initial_title` instead of `class` / `title` |
| `workspace` | `{"type":"none"}`, `{"type":"id","id":1..9999}`, `{"type":"special","name":"^[A-Za-z0-9_-]{1,32}$"}`, `{"type":"monitor-slot","monitor":"desc:…","slot":1..10}`, or `{"type":"resolver","resolver":"^[a-z0-9-]{1,32}$","arg":1..99}` | `{"type":"none"}` | static `workspace` for `id`/`special`; `workspace = "unset"` and `window.open` move for `monitor-slot`/`resolver` |
| `follow` | boolean | `true` | static: `false` appends ` silent`; dynamic: see **Targets and precedence** |
| `layout` | `"default"`, `"tile"`, or `"float"` | `"default"` | `tile = true` / `float = true` (`"default"` emits nothing) |
| `size` | `null` or `[w, h]` integers `1`–`16384` | `null` | `size = { w, h }` |
| `position` | `{"type":"none"}`, `{"type":"center"}`, or `{"type":"at","x":0..16384,"y":0..16384}` | `{"type":"none"}` | `center = true` or `move = { x, y }` (monitor-relative) |
| `monitor` | `null` or `desc:<description>` (6–128 code points, e.g. `desc:Vendor Model Serial`) | `null` | `monitor = "desc:…"` |
| `fullscreen` | boolean (cannot combine with `maximize`) | `false` | `fullscreen = true` when `true` |
| `maximize` | boolean (cannot combine with `fullscreen`) | `false` | `maximize = true` when `true` |
| `pin` | boolean | `false` | `pin = true` when `true` |
| `opacity` | `null` or number `0.05`–`1.0` | `null` | `opacity = "<n>"` |
| `noInitialFocus` | boolean | `false` | `no_initial_focus = true` when `true` |

`null` is accepted only for `size`, `monitor`, and `opacity`; omit any other optional field to take its default. Normalization keeps only the class key of the rule's `match.mode` (`classes` in `"apps"` mode, `class` in `"regex"` mode). Note that while omitting `match.mode` or `match.titleMode` in a hand-written file defaults to `"regex"` for compatibility with earlier files, rules created or captured in the panel start with `mode: "apps"` and `titleMode: "exact"`.

Example `rules.json` with an **Apps**-mode rule and a **Regex**-mode rule:

```json
{
  "version": 1,
  "revision": 2,
  "rules": [
    {
      "id": "editors",
      "name": "Editors",
      "enabled": true,
      "match": {
        "mode": "apps",
        "classes": [
          "org.example.Editor",
          "org.example.Notes"
        ],
        "title": "",
        "titleMode": "exact",
        "initial": false
      },
      "workspace": {
        "type": "special",
        "name": "scratchpad"
      },
      "follow": false,
      "layout": "float",
      "size": [1280, 800],
      "position": { "type": "center" },
      "monitor": null,
      "fullscreen": false,
      "maximize": false,
      "pin": false,
      "opacity": 0.95,
      "noInitialFocus": false
    },
    {
      "id": "games",
      "name": "Games",
      "enabled": true,
      "match": {
        "mode": "regex",
        "class": "^(game-launcher|game_app_.+)$",
        "title": "^Game .+$",
        "titleMode": "regex",
        "initial": false
      },
      "workspace": {
        "type": "resolver",
        "resolver": "external-slot",
        "arg": 3
      },
      "follow": false,
      "layout": "default",
      "size": null,
      "position": { "type": "none" },
      "monitor": null,
      "fullscreen": true,
      "maximize": false,
      "pin": false,
      "opacity": null,
      "noInitialFocus": true
    }
  ]
}
```

### Validation order

Both `hypr/schema.lua` and `Model.js` enforce the same validation order and defaults (verified against `tests/fixtures/conformance.json`). The first failing check determines the error code.

**Raw file and JSON checks** (before schema validation):

1. Missing file (`ENOENT`): valid empty state (`0` rules, `revision = 0`), not an error. A zero-byte file exists and proceeds to step 4 (`invalid-json`).
2. File cannot be opened or read → `file-unreadable`.
3. File exceeds 1,048,576 UTF-8 bytes → `file-too-large`.
4. Strict RFC 8259 JSON parse (refusing UTF-8 BOM, empty input, trailing tokens, lone surrogates / invalid UTF-8, unescaped control characters, non-finite / out-of-range numbers, and nesting deeper than 64) → `invalid-json`.

**Document-level checks** (first failure rejects the document):

1. Top-level value must be a JSON object and `version` must be a number → `invalid-file`.
2. If `version` is an integer `> 1` → `unsupported-version`.
3. `version` must equal integer `1` → `invalid-file`.
4. `revision` (optional, default `0`; `null` rejected): integer `0`–`9007199254740991` (`2^53 - 1`) → `invalid-revision`.
5. `rules` must be a JSON array → `invalid-file`.
6. `rules` length must be `<= 200` → `too-many-rules`.

**Rule-level checks** (evaluated independently per rule in array order; first failure skips that rule):

1. Entry must be a JSON object → `invalid-rule`.
2. `id` (required): string matching `^[a-z0-9][a-z0-9-]{0,47}$` → `invalid-id`.
3. `id` uniqueness: already claimed by an earlier rule → `duplicate-id`. Otherwise `id` is claimed immediately, even if this rule fails a later check.
4. `name` (required): valid UTF-8 string of 1–80 code points without control characters → `invalid-name`.
5. `enabled` (optional, default `true`): boolean → `invalid-flag`.
6. `match` (required object), `match.mode` (optional, default `"regex"`; `"apps"` or `"regex"`), and its class side: in `"apps"` mode, `match.classes` must be a JSON array of 1–32 strings of 1–256 code points without control characters; in `"regex"` mode, `match.class` must be 1–256 code points without control characters and passing the RE2 forbidden-construct scan → `invalid-class`.
7. `match.titleMode` (optional, default `"regex"`; `"exact"` or `"regex"`) and `match.title` (optional, default `""`; `null` rejected): 0–256 code points without control characters, plus the RE2 forbidden-construct scan when `titleMode` is `"regex"` → `invalid-title`.
8. `match.initial` (optional, default `false`; `null` rejected): boolean → `invalid-flag`.
9. `workspace` (optional, default `{"type":"none"}`): valid `none`, `id`, `special`, `monitor-slot`, or `resolver` object → `invalid-workspace`.
10. `follow` (optional, default `true`): boolean → `invalid-flag`.
11. `layout` (optional, default `"default"`): `"default"`, `"tile"`, or `"float"` → `invalid-layout`.
12. `size` (optional, default `null`): `null` or `[w, h]` integers `1`–`16384` → `invalid-size`.
13. `position` (optional, default `{"type":"none"}`): valid `none`, `center`, or `at` (`x`, `y` integers `0`–`16384`) → `invalid-position`.
14. `monitor` (optional, default `null`): `null` or `desc:<description>` string of 6–128 code points without control characters → `invalid-monitor`.
15. Effect flags, in order — `fullscreen`, `maximize`, `pin`, `noInitialFocus` (each optional, default `false`): boolean → `invalid-flag`.
16. `opacity` (optional, default `null`): `null` or finite number `0.05`–`1.0` → `invalid-opacity`.
17. `fullscreen` and `maximize` both `true` → `conflicting-effects`.
18. Non-blocking warning: `size` non-null or `position.type ~= "none"` while `layout ~= "float"` → `warn-geometry-not-floating`.

## Diagnostics

### Inspect the Lua loader

```bash
hyprctl repl 'return window_rules.describe()'
```

Example output (pretty-printed):

```json
{
  "api": 1,
  "counters": {
    "matched": 12,
    "moved": 5,
    "opened": 34
  },
  "dynamic": 2,
  "errors": [],
  "loaded": true,
  "loaderVersion": "1.0.0",
  "resolvers": [
    {
      "argLabel": "Slot",
      "label": "External display slot",
      "name": "external-slot"
    }
  ],
  "revision": 7,
  "rules": 4,
  "schema": 1
}
```

Errors are deduplicated per `(id, index, code)` and capped at 200 entries, so a resolver that fails on every window open is recorded once per rule while separate invalid rules keep their own entries with their 1-based `index`. `id` and `index` are `null` for file-level or global loader errors. In the panel, per-rule loader errors appear on their rule row (matched by 1-based `index`, falling back to `id` if the list was reordered), global errors appear in the **LOADER** section above the list, and each `detail` is shown as plain text truncated to one line of at most 160 characters.

### Error codes

| Code | Meaning |
|---|---|
| `file-unreadable` | `rules.json` exists but could not be opened or read |
| `file-too-large` | `rules.json` exceeds the 1 MiB (1,048,576-byte) limit |
| `invalid-json` | `rules.json` is not valid RFC 8259 JSON (including a zero-byte file, UTF-8 BOM, trailing tokens, lone surrogates, out-of-range numbers, or nesting deeper than 64) |
| `using-backup` | `rules.json` could not be used, so the loader applied a valid `rules.json.bak` instead (`detail` names the original file error code) |
| `invalid-file` | Top-level JSON is not an object, `version` is missing or not integer `1`, or `rules` is not an array |
| `unsupported-version` | `version` is an integer greater than `1` (written by a newer version of the plugin) |
| `invalid-revision` | `revision` is present and not an integer from `0` to `9007199254740991` (`2^53 - 1`) |
| `too-many-rules` | `rules` contains more than 200 entries |
| `invalid-rule` | A rule entry in `rules` is not a JSON object |
| `invalid-id` | `id` is missing or does not match `^[a-z0-9][a-z0-9-]{0,47}$` |
| `duplicate-id` | Another earlier rule already uses this `id` (the first rule keeps it; later ones are skipped) |
| `invalid-name` | `name` is missing, not 1–80 Unicode code points, invalid UTF-8, or contains a control character |
| `invalid-flag` | `enabled`, `match.initial`, `follow`, `fullscreen`, `maximize`, `pin`, or `noInitialFocus` is not a boolean |
| `invalid-class` | `match` is missing, `match.mode` is not `"apps"` or `"regex"`, `match.classes` is not 1–32 valid strings in `"apps"` mode, or `match.class` fails length, control-character, or refused-construct checks in `"regex"` mode |
| `invalid-title` | `match.titleMode` is not `"exact"` or `"regex"`, or `match.title` fails length, control-character, or (in `"regex"` mode) refused-construct checks |
| `pattern-syntax` | Editor-only: a regex-mode `match.class` or regex-mode `match.title` passed schema checks but did not compile in JavaScript `RegExp` (blocks saving only when new or edited) |
| `invalid-workspace` | `workspace` is not a valid `none`, `id`, `special`, `monitor-slot`, or `resolver` target |
| `invalid-layout` | `layout` is not `"default"`, `"tile"`, or `"float"` |
| `invalid-size` | `size` is neither `null` nor `[w, h]` integers in `1`–`16384` |
| `invalid-position` | `position` is not a valid `none`, `center`, or `at` (`x`, `y` integers in `0`–`16384`) |
| `invalid-monitor` | `monitor` is neither `null` nor a `desc:<description>` string of 6–128 code points without control characters |
| `invalid-opacity` | `opacity` is neither `null` nor a number in `0.05`–`1.0` |
| `conflicting-effects` | Both `fullscreen` and `maximize` are `true` on the same rule |
| `resolver-missing` | A rule references a resolver name that was not registered with `window_rules.register_resolver` |
| `resolver-failed` | A registered resolver raised an error or returned something other than `nil` or `{ workspace = <integer >= 1>, monitor = <string or nil> }` |
| `capability-missing` | Hyprland or Omarchy lacks a required Lua function (`detail` is `"missing capability: <path>"`; missing `o.window` stops all rules, while any missing path in `required_api` disables dynamic targets and still registers static rules) |
| `register-failed` | Hyprland refused to register that rule via `o.window`; the rule is skipped and the remaining rules still load |
| `handler-failed` | An unexpected Lua error was caught inside `load()`, the `window.open` handler, or `move_window()` |

### Warning codes

Non-blocking warnings shown in the editor:

| Code | Meaning |
|---|---|
| `warn-geometry-not-floating` | Size or position is set while **Layout** is not **Float** |
| `capture-position-clamped` | Captured floating window was partly off its display; its position was clamped into `0`–`16384` |
| `capture-workspace-unsupported` | Captured window's workspace cannot be targeted by a rule |
| `warn-pattern-unchecked` | A regex pattern uses RE2 flags the editor cannot check (`(?U)` or a flag group after the start); Hyprland checks it when the rules load |
| `warn-pattern-negative` | A regex pattern starts with `negative:`, matching windows the rest of the pattern does not match |

### Diagnostics freshness, loader notes, and Hyprland config errors

The panel queries `window_rules.describe()` and `hyprctl configerrors` at startup, when opened, after every save (`hyprctl reload` → `describe()` → `configerrors`), on Hyprland's `configreloaded` event, and whenever `rules.json` changes outside this bar (such as a hand edit or a save from another monitor's bar). Opening the panel clears status errors from an earlier save and re-checks the loader; `configreloaded` and external file changes refresh loader state and config errors while keeping any existing save error visible. `omarchy-shell io.github.ltecosta.window-rules state` reflects these refreshes automatically. (Runtime errors recorded on a later `window.open` without a reload or file change appear on the next panel open, reload, or file change.)

Any Hyprland configuration errors (up to 50 lines) and any loader compatibility notes appear above the rule list:

- **Revision mismatch** (`loader.revisionMismatch`): `Hyprland loaded revision <loaded>, but revision <written> was written`
- **Loader version mismatch** (`loader.versionMismatch`): `The loader in use is version <loader> and the plugin is version <plugin>; reinstall the plugin and reload Hyprland`
- **Older loader schema** (`loader.schemaOlder`): `The loader in use reads rules format <loader>, older than format <panel> that this panel writes; reinstall the plugin and reload Hyprland`
- **Newer loader API** (`loader.apiNewer`): `The loader in use reports API <loader>, newer than the API <panel> this panel knows; update the plugin`

You can also inspect the panel with `omarchy-shell io.github.ltecosta.window-rules state` and Hyprland directly with `hyprctl configerrors`.

## Lifecycle

- **Disabling the widget**: disabling or removing the widget from the bar (`omarchy plugin disable io.github.ltecosta.window-rules`) stops only the bar UI; your rules keep working because Hyprland loads `hypr/window-rules.lua` and `rules.json` directly without the shell.
- **Removing the plugin**: running `omarchy plugin remove io.github.ltecosta.window-rules` deletes the plugin files; the `io.open` and `pcall(dofile, path)` guard in `~/.config/hypr/hyprland.lua` skips the block cleanly so Hyprland starts with no errors and none of the plugin's rules applied.
- **Updating**: reinstall or update the plugin (for example `scripts/install window-rules`), run `omarchy-restart-shell` so the shell loads updated QML, and run `hyprctl reload` so Hyprland loads the updated Lua loader. If the loaded Lua version, rules schema format, or `describe()` API differs from what the panel expects, the panel shows the corresponding note (`loader.versionMismatch`, `loader.schemaOlder`, or `loader.apiNewer`).
- **Backup fallback**: if `rules.json` becomes unreadable or fails JSON/document validation (including a zero-byte file), `window_rules.load()` automatically loads a valid `rules.json.bak` and records `using-backup`, keeping your last valid rules active until you fix `rules.json` or click **Restore the last valid version** in the panel.
- **Uninstall**:
  1. Remove the loader block (and any key bindings) from `~/.config/hypr/hyprland.lua` (and `~/.config/hypr/bindings.lua` if bound there) and run `hyprctl reload`.
  2. Run `omarchy plugin remove io.github.ltecosta.window-rules` (or `omarchy plugin disable io.github.ltecosta.window-rules` and remove `~/.config/omarchy/plugins/io.github.ltecosta.window-rules`), then run `omarchy-restart-shell`.
  3. Optionally delete `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/io.github.ltecosta.window-rules/` if you no longer want `rules.json` and `rules.json.bak`.

## Development

From the repository root, run the full check suite:

```bash
scripts/check
```

`scripts/check` validates `manifest.json` (and runs `omarchy-plugin-validate` when installed), checks every JSON file with `jq`, runs the Node tests, runs every Lua test file on every installed Lua interpreter at version 5.4 or later (`lua5.4`, `lua5.5`, `lua` — failing if none is installed), runs headless Quickshell smoke tests (skipping with a notice if `qs` is not installed), and runs `qmllint` on every non-test QML file (`qmllint` is required and fails the check if missing).

From `plugins/window-rules/`, the individual test files are:

- `tests/model.test.js` (`node --test`): `Model.js` validation, shared conformance cases (object, raw-text, and `compileCases`), exact-app and RE2/pattern checks, capture, serialization, save/restore plans, writer lock logic, conflict reapplication, invalid-rule repair, panel helpers (hero state, summary counts, target badges/glyphs), and README/example documentation checks.
- `tests/shared.test.js` (`node --test`): `Shared.js` monitor-scoped cross-instance capture handoff, 5-second TTL expiry, empty-capture delivery, and open-panel tracking.
- `tests/json_test.lua` (`lua5.4 tests/json_test.lua`): `hypr/json.lua` strict RFC 8259 decoder and deterministic encoder.
- `tests/schema_test.lua` (`lua5.4 tests/schema_test.lua`): `hypr/schema.lua` validation and `compile_match` against `tests/fixtures/conformance.json`.
- `tests/loader_test.lua` (`lua5.4 tests/loader_test.lua`): `hypr/window-rules.lua` mapping, per-rule `register-failed` isolation, candidate precedence, `workspace = "unset"`, static fallback without sibling filter, resolver failure fallback, position reapplication, sibling rules, dynamic focus/silent restoration, resolvers, backup fallback, capability checks, `move_window()`, `describe()` counters/errors, and error recovery with stubbed `hl` and `o` globals.
- `tests/contract_test.lua` (`lua5.4 tests/contract_test.lua`): checks `required_api` and `required_fields` (`HL.Window`, `HL.Monitor`, `HL.Workspace`) against `/usr/share/hypr/stubs/hl.meta.lua` (when present) and exercises `examples/hyprland.lua`.
- `tests/store.smoke.sh` (`bash tests/store.smoke.sh`, with `tests/smoke/{shell.qml,panel.qml,KeyboardPanel.qml,hyprctl,stat}`): headless Quickshell smoke tests for `Store.qml` and `Panel.qml` covering saves, conflicts, concurrent writers, stale-lock takeover, zero-byte file and backup restore, failed and timed-out reloads, `configreloaded` and external-change loader refreshes, queued and monitor-scoped captures, delete-after-reorder confirmation, edits held during saves, the 32-app and 200-rule limits, and capture refusal on non-editable views.
- `tests/fixtures/conformance.json`: shared schema conformance fixtures (object, raw-text, and `compileCases`) that both `Model.js` and `hypr/schema.lua` must satisfy.
- `tests/lua_helpers.lua`: shared assertion helpers for the Lua test suites.

After installing changes, run `omarchy-restart-shell` for QML edits and `hyprctl reload` for Lua edits, then check `journalctl --user -o cat` for shell warnings naming the plugin.

## License

MIT
