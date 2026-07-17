#!/usr/bin/env bash
# open-settings-pane.sh — KEY_SETTINGS handler: open plugin settings in herdr.
# Triggered from inside the lazygit pane by its customCommand (from the
# generated.yml layer), so HERDR_PANE_ID / HERDR_TAB_ID point to the sidebar.
#
# Behavior (the same geometry pattern as open-ai-commit-pane.sh):
#   - close any existing "GitSettings" pane in this tab (single instance)
#   - split a Settings pane to the right of the sidebar; layout-helper.py
#     place-diff arranges the (sidebar | settings) region as
#     SIDEBAR_COLS + SETTINGS_COLS columns
#   - run settings-fzf.sh in the pane; on exit (Esc/q), set-region-width restores
#     the sidebar/expanded width from before opening, then exit closes the pane
#
# bash 3.2 compatible (macOS default).
set -euo pipefail

[ "${HERDR_ENV:-}" = "1" ] || { echo "open-settings-pane.sh: not inside herdr" >&2; exit 1; }
herdr_bin="${HERDR_BIN_PATH:-herdr}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
helper="$script_dir/layout-helper.py"
settings_sh="$script_dir/settings-fzf.sh"
# shellcheck disable=SC1091
. "$script_dir/layout-layer.sh"

# Quoting safety: bash 3.2's printf %q breaks multibyte UTF-8 (such as paths
# containing non-ASCII characters) into invalid byte sequences, causing the
# herdr CLI (Rust) to panic. Use python3 shlex.quote consistently: wrap with
# single quotes while preserving the original UTF-8 bytes.
shq() { python3 -c 'import shlex, sys; sys.stdout.write(shlex.quote(sys.argv[1]))' "$1"; }

# --- Geometry: default sidebar 42 columns / Settings 70; panel.conf overrides -
SIDEBAR_COLS=42
EXPAND_COLS=110
SETTINGS_COLS=70
config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
panel_conf="$config_dir/panel.conf"
layout_file="${HERDR_LAZYGIT_LAYOUT_FILE:-}"
# shellcheck disable=SC1090
[ -f "$panel_conf" ] && . "$panel_conf"
case "$SIDEBAR_COLS" in *[!0-9]*|'') SIDEBAR_COLS=42 ;; esac
case "$EXPAND_COLS" in *[!0-9]*|'') EXPAND_COLS=110 ;; esac
case "$SETTINGS_COLS" in *[!0-9]*|'') SETTINGS_COLS=70 ;; esac
[ "$SIDEBAR_COLS" -ge 20 ] 2>/dev/null || SIDEBAR_COLS=42
[ "$EXPAND_COLS" -ge 80 ] 2>/dev/null || EXPAND_COLS=80
[ "$SETTINGS_COLS" -ge 40 ] 2>/dev/null || SETTINGS_COLS=70
LAYOUT_MODE="$(herdr_lazygit_read_layout_mode "$layout_file")"

# Temporarily set lazygit to sidebar width while Settings is visible; restore the
# mode active at invocation when it exits.
restore_cols="$SIDEBAR_COLS"
if [ "$LAYOUT_MODE" = "expanded" ]; then
  restore_cols="$EXPAND_COLS"
  tab_width="$("$herdr_bin" pane layout --pane "$HERDR_PANE_ID" 2>/dev/null | python3 -c '
import json, sys
try:
    print(int(json.load(sys.stdin)["result"]["layout"]["area"]["width"]))
except Exception:
    print(0)
' || echo 0)"
  case "$tab_width" in *[!0-9]*|'') tab_width=0 ;; esac
  if [ "$tab_width" -gt 20 ]; then
    max_cols=$((tab_width - 20))
    [ "$restore_cols" -le "$max_cols" ] || restore_cols="$max_cols"
  fi
fi

# --- Single instance: close an existing GitSettings pane in this tab --------
panes_json="$("$herdr_bin" pane list 2>/dev/null || true)"
printf '%s' "$panes_json" | python3 -c '
import json, sys
tab = sys.argv[1]
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    panes = []
for p in panes:
    if p.get("tab_id") == tab and p.get("label") == "GitSettings":
        print(p["pane_id"])
' "$HERDR_TAB_ID" | while read -r old; do "$herdr_bin" pane close "$old" >/dev/null 2>&1 || true; done

# --- Open the Settings pane and apply its geometry --------------------------
new_pane="$("$herdr_bin" pane split --pane "$HERDR_PANE_ID" --direction right --ratio 0.5 --focus 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
[ -n "$new_pane" ] || { echo "open-settings-pane.sh: pane split failed" >&2; exit 1; }

"$herdr_bin" pane rename "$new_pane" "GitSettings" >/dev/null 2>&1 || true
python3 "$helper" place-diff "$HERDR_PANE_ID" "$new_pane" "$SIDEBAR_COLS" "$SETTINGS_COLS" 2>/dev/null || true

# Restore lazygit's width before exit. If settings-fzf.sh fails (for example,
# fzf is missing), sleep so the message remains readable. The final exit makes
# the pane disappear immediately after q/Esc.
restore_cmd="python3 $(shq "$helper") set-region-width $(shq "$HERDR_PANE_ID") $(shq "$restore_cols")"
# Pass the Herdr binary and configuration directory explicitly. pane run starts
# a fresh shell that does not inherit these values from lazygit (the plugin
# pane). Without them, Settings can write to the fallback directory and the
# restore helper can call the wrong Herdr binary.
if ! "$herdr_bin" pane run "$new_pane" "clear; export HERDR_BIN_PATH=$(shq "$herdr_bin") HERDR_PLUGIN_CONFIG_DIR=$(shq "$config_dir"); bash $(shq "$settings_sh") || sleep 4; $restore_cmd >/dev/null 2>&1; exit" >/dev/null; then
  # A failed run leaves an empty shell pane; close it and restore the sidebar so
  # the user is not left with debris.
  "$herdr_bin" pane close "$new_pane" >/dev/null 2>&1 || true
  python3 "$helper" set-region-width "$HERDR_PANE_ID" "$restore_cols" >/dev/null 2>&1 || true
  echo "open-settings-pane.sh: pane run failed" >&2
  exit 1
fi
