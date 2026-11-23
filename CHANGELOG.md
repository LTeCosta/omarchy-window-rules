# Changelog

## 1.0.0

### Panel
- Bar widget and keyboard-driven panel (`j`/`k`, `h`/`l`, `Ctrl+j`/`Ctrl+k`, `n`, `c`, `d`, `x`, `s`, Space, Enter, Tab, Escape), verified with Omarchy `4.5.0-3`.
- Status hero with quick-capture button, four summary tiles (**RULES**, **DYNAMIC**, **MOVED**, **ERRORS**), and compact rule rows with target glyphs, badges, and cursor-revealed actions.
- Sectioned rule editor (**MATCH**, **PLACEMENT**, **WINDOW**, **STATE**) with inline numeric steppers and view-specific pinned footer buttons.
- Pending list drafts for ordering, enabling, disabling, duplicating, and deleting rules before saving with a single reload.
- In-place repair flow when opening an invalid rule, marking reset fields and keeping valid and unknown fields.

### Matching
- **Apps** mode (default for captures and new rules) matching 1–32 exact window classes picked from open windows or added by class name without escaping, refusing a 33rd class with a notice.
- **Regex** mode for RE2 full-match patterns, supporting leading `(?i)`/`(?m)`/`(?s)` flags, `negative:` patterns, and approximate open-window match previews.
- **Title** matching (**Off**, **Exact**, **Regex**) and **Opened with** (`initial_class` / `initial_title`), compiled identically by `Model.js` and `hypr/schema.lua`.

### Capture and IPC
- `open`, `close`, and `toggle` IPC commands routed through `omarchy-shell shell summon|hide|toggle` for the focused monitor.
- Focused-window `capture` IPC reading the window and monitors before opening the panel and delivering the capture to the focused monitor's panel through `Shared.js`.
- Refusal of incoming captures with a notice while the panel shows the conflict, invalid-file, or unsupported-file view, or while a save is running; confirmation before replacing an unsaved rule in the editor.
- **Pick window** dropdown to pre-fill a rule from any open window's class, title, workspace or display slot, floating geometry, fullscreen/maximize state, and pin flag.

### Saving
- Atomic `rules.json` v1 storage (`0600` in a `0700` state directory) with a 200-rule limit, 1 MiB UTF-8 cap, and unknown-field preservation.
- Atomic `rules.lock` writer lock with atomic rename-and-recheck takeover of stale locks older than 30 seconds.
- Full-content conflict detection that keeps an in-editor rule for **Reapply my rule** (checking the 200-rule limit before clearing the conflict view).
- Read-only locking of list and editor edits while a save runs, keeping any draft version different from the submitted one.
- Delete and backup-restore confirmations checked against the frozen rule entry or file state shown when the dialog opened.
- Automatic `rules.json.bak` backup of the last valid file, with one-click restore in the panel (including for zero-byte files).

### Loader
- Hyprland Lua loader (`hypr/window-rules.lua`, `api_version = 1`) loaded under `pcall(dofile, ...)` so rules apply without the shell running.
- Static targets (workspace number, special workspace) and dynamic targets (display slot by monitor description and custom Lua resolvers registered with `register_resolver`).
- Per-rule `pcall` registration so a rule Hyprland refuses records `register-failed` while the remaining rules still load.
- Precedence walk with `workspace = "unset"` on dynamic rules, continuing past declining, missing, or failing resolvers and applying an earlier static target with static semantics (no sibling filter).
- Sibling focus rule for dynamic targets by `(pid, class)`, silent focus restoration preserving every monitor's regular workspace and visible special workspaces, independent position reapplication, backup fallback (`using-backup`), and public `move_window()`.

### Diagnostics
- `window_rules.describe()`, `omarchy-shell io.github.ltecosta.window-rules state`, and `hyprctl configerrors` integration.
- Automatic loader refresh at startup, on panel open, after saves, on Hyprland's `configreloaded` event, and on outside changes to `rules.json`.
- Per-rule and global loader errors in the panel, plus notes for revision mismatch, loader version mismatch, older loader schema, and newer loader API.
