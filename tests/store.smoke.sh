#!/usr/bin/env bash
# Smoke test of Store.qml and Panel.qml in a headless Quickshell.
#
# The store run (smoke/shell.qml, two stores on one state directory): save,
# conflict, two writers at once, a zero-byte file and its restore, a restore
# refused after a repair, a failed and a hung reload, the writer lock and its
# stale takeover, the loader refresh, and queued captures.
#
# The panel run (smoke/panel.qml, one panel without a bar, built on the
# installed Omarchy shell kit with a stand-in KeyboardPanel): a delete after
# the list was reordered elsewhere, edits during a save, captures by monitor
# and under views that hide the editor, a 33rd app, reapplying onto a full
# file, and a restore refused after a repair. It is skipped when the kit is
# not installed.
#
# Everything runs in a temporary directory with a fake hyprctl, a fake
# omarchy-shell and a stat wrapper first on PATH; the live shell, the real
# state directory and Hyprland are never touched. Skips itself when qs is
# missing.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin=$(dirname "$here")
kit=${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}

if ! command -v qs >/dev/null; then
  echo "store.smoke.sh: skipped: qs not installed"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config" "$tmp/bin" "$tmp/fake" "$tmp/home" "$tmp/run" "$tmp/state"
chmod 700 "$tmp/run"
cp "$plugin/Store.qml" "$plugin/Model.js" "$here/smoke/shell.qml" "$tmp/config/"
cp "$here/smoke/hyprctl" "$tmp/bin/hyprctl"
cp "$here/smoke/stat" "$tmp/bin/stat"
printf '%s\n' '#!/usr/bin/env bash' 'printf "omarchy-shell %s\n" "$*" >> "${FAKE_HYPRCTL_DIR:?}/calls"' > "$tmp/bin/omarchy-shell"
chmod 755 "$tmp/bin/hyprctl" "$tmp/bin/stat" "$tmp/bin/omarchy-shell"
real_stat=$(command -v stat)
: > "$tmp/fake/calls"

# An existing state directory with a loose mode, and a valid file at revision 1.
state="$tmp/state/omarchy/io.github.ltecosta.window-rules"
mkdir -p "$state"
chmod 755 "$state"
printf '%s\n' '{"version":1,"revision":1,"comment":"kept","rules":[{"id":"seed","name":"Seed","match":{"class":"^seed$"},"future":true}]}' > "$state/rules.json"
cp "$state/rules.json" "$tmp/fake/seed.json"
# Files the driver copies into place: a repair made by another bar, a hand
# edit, Hyprland config errors, and the lock path the stat wrapper swaps.
printf '%s\n' '{"version":1,"revision":40,"rules":[]}' > "$tmp/fake/repaired.json"
printf '%s\n' '{"version":1,"revision":50,"rules":[]}' > "$tmp/fake/external.json"
printf '%s\n' 'smoke: config error' > "$tmp/fake/config-errors.src"
printf '%s' "$state/rules.lock" > "$tmp/fake/lock-path"

failed=0
checks=0

# run_driver <name> <config dir> <state home> <rules path>: runs the driver
# <config dir>/shell.qml and reports its lines.
run_driver() {
  local name=$1 config=$2 state_home=$3 rules=$4 output status results done_line
  output=$(cd "$tmp" && env -u HYPRLAND_INSTANCE_SIGNATURE -u WAYLAND_DISPLAY -u DISPLAY -u QT_QPA_PLATFORMTHEME -u QT_IM_MODULE \
    HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" XDG_STATE_HOME="$state_home" XDG_CONFIG_HOME="$tmp/home/.config" \
    XDG_CACHE_HOME="$tmp/home/.cache" XDG_DATA_HOME="$tmp/home/.local/share" \
    PATH="$tmp/bin:$PATH" FAKE_HYPRCTL_DIR="$tmp/fake" FAKE_RULES="$rules" REAL_STAT="$real_stat" \
    QT_QPA_PLATFORM=offscreen QML_XHR_ALLOW_FILE_READ=1 NO_COLOR=1 \
    timeout 120 qs -p "$config/shell.qml" 2>&1)
  status=$?

  # Only the driver's lines, without log prefixes or colours.
  results=$(printf '%s\n' "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'SMOKE .*' | sed 's/^SMOKE //')
  printf '%s\n' "$results" | grep -v '^done ' | sed 's/^/store.smoke.sh: /'

  done_line=$(printf '%s\n' "$results" | grep '^done ' | tail -n 1)
  if [[ $done_line != "done 0" ]] || printf '%s\n' "$results" | grep -q '^not ok'; then
    echo "store.smoke.sh: $name run FAILED (qs exit $status${done_line:+, $done_line})" >&2
    [[ -z $done_line ]] && printf '%s\n' "$output" | tail -n 40 >&2
    failed=1
  fi
  checks=$((checks + $(printf '%s\n' "$results" | grep -c '^ok')))
}

run_driver store "$tmp/config" "$tmp/state" "$state/rules.json"

if [[ -d $kit/Ui && -d $kit/Commons ]]; then
  # The plugin as installed, the kit's Commons and Ui, and a KeyboardPanel
  # that needs no layer-shell window.
  panel_config="$tmp/panel-config"
  mkdir -p "$panel_config/Ui" "$tmp/panel-state"
  cp "$plugin"/*.qml "$plugin"/*.js "$plugin/manifest.json" "$panel_config/"
  cp -r "$plugin/i18n" "$panel_config/"
  cp "$here/smoke/panel.qml" "$panel_config/shell.qml"
  ln -s "$kit/Commons" "$panel_config/Commons"
  for file in "$kit"/Ui/*; do
    [[ ${file##*/} == KeyboardPanel.qml ]] || ln -s "$file" "$panel_config/Ui/"
  done
  cp "$here/smoke/KeyboardPanel.qml" "$panel_config/Ui/KeyboardPanel.qml"

  panel_state="$tmp/panel-state/omarchy/io.github.ltecosta.window-rules"
  mkdir -p "$panel_state"
  rule() { printf '{"id":"%s","name":"%s","match":{"class":"^%s$"}}' "$1" "$2" "$1"; }
  list() { local IFS=,; printf '{"version":1,"revision":%s,"rules":[%s]}\n' "$1" "${*:2}"; }
  list 1 "$(rule a Alpha)" "$(rule b Beta)" "$(rule c Gamma)" > "$panel_state/rules.json"
  list 2 "$(rule b Beta)" "$(rule a Alpha)" "$(rule c Gamma)" > "$tmp/fake/reordered.json"
  many=()
  for i in $(seq 1 199); do many+=("$(rule "r$i" "Rule $i")"); done
  list 10 "${many[@]}" > "$tmp/fake/rules-199.json"
  list 11 "${many[@]}" "$(rule r200 "Rule 200")" > "$tmp/fake/rules-200.json"

  run_driver panel "$panel_config" "$tmp/panel-state" "$panel_state/rules.json"
else
  echo "store.smoke.sh: panel run skipped: no Omarchy shell kit at $kit"
fi

if (( failed )); then
  echo "store.smoke.sh: FAILED" >&2
  exit 1
fi
echo "store.smoke.sh: passed ($checks checks)"
