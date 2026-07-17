#!/usr/bin/env bash
# toggle-expand.sh — KEY_ZOOM handler: expand/collapse lazygit itself.
#
# Each lazygit pane inherits HERDR_LAZYGIT_LAYOUT_FILE from run-lazygit.sh. A
# toggle rewrites only that per-pane YAML layer, adjusts the current lazygit
# pane's absolute width, and then injects CSI focus-in so lazygit hot-reloads
# the changed layout immediately. The script is called by a lazygit
# customCommand, so HERDR_PANE_ID is this pane.
#
# bash 3.2 compatible (macOS default).
set -euo pipefail

[ "${HERDR_ENV:-}" = "1" ] || { echo "toggle-expand.sh: not inside herdr" >&2; exit 1; }
[ -n "${HERDR_PANE_ID:-}" ] || { echo "toggle-expand.sh: HERDR_PANE_ID is empty" >&2; exit 1; }
[ -n "${HERDR_LAZYGIT_LAYOUT_FILE:-}" ] || {
  echo "toggle-expand.sh: HERDR_LAZYGIT_LAYOUT_FILE is empty" >&2
  exit 1
}
herdr_bin="${HERDR_BIN_PATH:-herdr}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
helper="${HERDR_LAZYGIT_LAYOUT_HELPER:-$script_dir/layout-helper.py}"
# shellcheck disable=SC1091
. "$script_dir/layout-layer.sh"
config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
panel_conf="$config_dir/panel.conf"
layout_file="$HERDR_LAZYGIT_LAYOUT_FILE"

SIDEBAR_COLS=42
EXPAND_COLS=110
# shellcheck disable=SC1090
[ -f "$panel_conf" ] && . "$panel_conf"

case "$SIDEBAR_COLS" in *[!0-9]*|'') SIDEBAR_COLS=42 ;; esac
case "$EXPAND_COLS" in *[!0-9]*|'') EXPAND_COLS=110 ;; esac
[ "$SIDEBAR_COLS" -ge 20 ] 2>/dev/null || SIDEBAR_COLS=42
[ "$EXPAND_COLS" -ge 80 ] 2>/dev/null || EXPAND_COLS=80
LAYOUT_MODE="$(herdr_lazygit_read_layout_mode "$layout_file")"

if [ "$LAYOUT_MODE" = "sidebar" ]; then
  next_mode="expanded"
  target_cols="$EXPAND_COLS"

  # After expanding, leave at least 20 columns for the tab's other workspace.
  # In a normal tab (>=100 columns), also keep lazygit at least 80 columns wide.
  # When a narrower tab cannot satisfy both constraints, preserve the workspace.
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
    [ "$target_cols" -le "$max_cols" ] || target_cols="$max_cols"
  fi
else
  next_mode="sidebar"
  target_cols="$SIDEBAR_COLS"
fi

herdr_lazygit_write_layout_layer "$layout_file" "$next_mode"
python3 "$helper" set-width "$HERDR_PANE_ID" "$target_cols"

# lazygit stats and hot-reloads all configuration on focus-in; inject the event
# directly to switch the layout immediately.
"$herdr_bin" pane send-text "$HERDR_PANE_ID" $'\x1b[I' >/dev/null
