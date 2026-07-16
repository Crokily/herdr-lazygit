#!/usr/bin/env bash
# open-ai-commit-pane.sh — KEY_COMMIT handler: open the AI commit editing pane.
#
# Triggered by lazygit's files customCommand. Its behavior mirrors the Settings
# pane:
#   - one GitCommit instance per tab
#   - open a COMMIT_COLS-wide pane to the right of the sidebar
#   - explicitly pass the configuration directory and repository cwd to the
#     new shell
#   - restore the sidebar/expanded width from invocation before the UI exits;
#     exit then closes the pane automatically
#
# bash 3.2 compatible (macOS default).
set -euo pipefail

[ "${HERDR_ENV:-}" = "1" ] || { echo "open-ai-commit-pane.sh: not inside herdr" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
helper="$script_dir/layout-helper.py"
commit_sh="$script_dir/ai-commit-pane.sh"
repo="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "open-ai-commit-pane.sh: not inside a git repository" >&2
  exit 1
}

# bash 3.2's printf %q corrupts multibyte UTF-8; generate every pane-run command
# fragment with python3 shlex.quote instead.
shq() { python3 -c 'import shlex, sys; sys.stdout.write(shlex.quote(sys.argv[1]))' "$1"; }

# --- Geometry ---------------------------------------------------------------
SIDEBAR_COLS=42
EXPAND_COLS=110
COMMIT_COLS=70
LAYOUT_MODE=sidebar
config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
panel_conf="$config_dir/panel.conf"
# shellcheck disable=SC1090
[ -f "$panel_conf" ] && . "$panel_conf"
case "$SIDEBAR_COLS" in *[!0-9]*|'') SIDEBAR_COLS=42 ;; esac
case "$EXPAND_COLS" in *[!0-9]*|'') EXPAND_COLS=110 ;; esac
case "$COMMIT_COLS" in *[!0-9]*|'') COMMIT_COLS=70 ;; esac
[ "$SIDEBAR_COLS" -ge 20 ] 2>/dev/null || SIDEBAR_COLS=42
[ "$EXPAND_COLS" -ge 80 ] 2>/dev/null || EXPAND_COLS=80
[ "$COMMIT_COLS" -ge 40 ] 2>/dev/null || COMMIT_COLS=70

# Temporarily set lazygit to sidebar width while the AI pane is visible; restore
# the mode active at invocation after it closes.
restore_cols="$SIDEBAR_COLS"
if [ "$LAYOUT_MODE" = "expanded" ]; then
  restore_cols="$EXPAND_COLS"
  tab_width="$(herdr pane layout --pane "$HERDR_PANE_ID" 2>/dev/null | python3 -c '
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

# --- Single instance: close an existing GitCommit pane in this tab ----------
panes_json="$(herdr pane list 2>/dev/null || true)"
printf '%s' "$panes_json" | python3 -c '
import json, sys
tab = sys.argv[1]
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    panes = []
for p in panes:
    if p.get("tab_id") == tab and p.get("label") == "GitCommit":
        print(p["pane_id"])
' "$HERDR_TAB_ID" | while read -r old; do herdr pane close "$old" >/dev/null 2>&1 || true; done

# --- Open the AI commit pane and apply its geometry -------------------------
new_pane="$(herdr pane split --pane "$HERDR_PANE_ID" --direction right --ratio 0.5 --focus 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
[ -n "$new_pane" ] || { echo "open-ai-commit-pane.sh: pane split failed" >&2; exit 1; }

herdr pane rename "$new_pane" "GitCommit" >/dev/null 2>&1 || true
python3 "$helper" place-diff "$HERDR_PANE_ID" "$new_pane" "$SIDEBAR_COLS" "$COMMIT_COLS" 2>/dev/null || true

restore_cmd="python3 $(shq "$helper") set-region-width $(shq "$HERDR_PANE_ID") $(shq "$restore_cols")"
run_cmd="clear; cd $(shq "$repo") && HERDR_PLUGIN_CONFIG_DIR=$(shq "$config_dir") bash $(shq "$commit_sh") $(shq "$repo"); $restore_cmd >/dev/null 2>&1; exit"
if ! herdr pane run "$new_pane" "$run_cmd" >/dev/null; then
  herdr pane close "$new_pane" >/dev/null 2>&1 || true
  python3 "$helper" set-region-width "$HERDR_PANE_ID" "$restore_cols" >/dev/null 2>&1 || true
  echo "open-ai-commit-pane.sh: pane run failed" >&2
  exit 1
fi
