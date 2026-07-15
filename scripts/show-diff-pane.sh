#!/usr/bin/env bash
# Show a diff in a dedicated herdr pane, using herdr (not lazygit) as the
# layout engine. Triggered by the `V` customCommand from inside the lazygit
# pane, so HERDR_PANE_ID / HERDR_TAB_ID identify the sidebar pane.
#
# Behavior:
#   - closes any previous "GitDiff" pane in this tab (only ever one at a time)
#   - splits the widest other pane in the tab (falls back to the sidebar pane,
#     splitting down) and runs the diff there through delta (or less)
#   - the pane runs "<diff> ; exit", so quitting the pager (q) closes the pane
#
# Usage: show-diff-pane.sh file <repo-relative-path>
#
# bash 3.2 compatible (macOS default).
set -euo pipefail

kind="${1:-file}"
target="${2:-}"
[ -n "$target" ] || exit 0
[ "${HERDR_ENV:-}" = "1" ] || { echo "show-diff-pane.sh: not inside herdr" >&2; exit 1; }

repo="$(git rev-parse --show-toplevel)"
q_repo="$(printf %q "$repo")"
q_target="$(printf %q "$target")"

# --- build the command that renders the diff -------------------------------
# With delta: pipe raw git output into it. Without: let git colorize, page with less.
if command -v delta >/dev/null 2>&1; then
  git_cmd="git -C $q_repo"
  pager="delta --paging=always"
else
  git_cmd="git -c color.diff=always -C $q_repo"
  pager="less -R"
fi

case "$kind" in
  file)
    if git -C "$repo" ls-files --error-unmatch -- "$target" >/dev/null 2>&1; then
      # tracked: staged + unstaged combined
      base_cmd="$git_cmd diff HEAD -- $q_target"
    else
      # untracked: diff against /dev/null (exits 1 by design, so || true)
      base_cmd="{ $git_cmd diff --no-index -- /dev/null $q_repo/$q_target || true; }"
    fi
    ;;
  commit)
    base_cmd="$git_cmd show $q_target"
    ;;
  *)
    echo "show-diff-pane.sh: unknown kind '$kind'" >&2; exit 1 ;;
esac

view_cmd="$base_cmd | $pager"

# --- geometry: the diff opens as a wide pane RIGHT of the sidebar ----------
# `pane split` can only divide the sidebar's own (narrow) rectangle, so after
# splitting we use layout-helper.py (layout.set_split_ratio over the herdr
# socket) to borrow width from the rest of the tab: the (git|diff) region
# grows to SIDEBAR_COLS+diff_cols, split SIDEBAR_COLS / diff_cols. Before the
# pager exits, the region shrinks back to SIDEBAR_COLS, so closing the diff
# leaves the sidebar at its configured width.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
helper="$script_dir/layout-helper.py"

SIDEBAR_COLS=42
DIFF_COLS=""   # empty -> 45% of the tab width
panel_conf="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}/panel.conf"
# shellcheck disable=SC1090
[ -f "$panel_conf" ] && . "$panel_conf"

# close the previous GitDiff pane in this tab (only ever one at a time)
panes_json="$(herdr pane list 2>/dev/null || true)"
printf '%s' "$panes_json" | python3 -c '
import json, sys
tab = sys.argv[1]
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    panes = []
for p in panes:
    if p.get("tab_id") == tab and p.get("label") == "GitDiff":
        print(p["pane_id"])
' "$HERDR_TAB_ID" | while read -r old; do herdr pane close "$old" >/dev/null 2>&1 || true; done

if [ -z "$DIFF_COLS" ]; then
  tab_w="$(herdr pane layout --pane "$HERDR_PANE_ID" 2>/dev/null | python3 -c '
import json, sys
print(json.load(sys.stdin)["result"]["layout"]["area"]["width"])' || echo 0)"
  DIFF_COLS=$(( tab_w * 45 / 100 ))
fi
[ "$DIFF_COLS" -ge 20 ] || DIFF_COLS=60

# --- open the pane and run the diff ----------------------------------------
new_pane="$(herdr pane split --pane "$HERDR_PANE_ID" --direction right --ratio 0.5 --focus 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
[ -n "$new_pane" ] || { echo "show-diff-pane.sh: pane split failed" >&2; exit 1; }

herdr pane rename "$new_pane" "GitDiff" >/dev/null 2>&1 || true
python3 "$helper" place-diff "$HERDR_PANE_ID" "$new_pane" "$SIDEBAR_COLS" "$DIFF_COLS" 2>/dev/null || true

# restore the sidebar width before exiting; "; exit" closes the pane on q
restore_cmd="python3 $(printf %q "$helper") set-region-width $(printf %q "$HERDR_PANE_ID") $(printf %q "$SIDEBAR_COLS")"
herdr pane run "$new_pane" "clear; $view_cmd; $restore_cmd >/dev/null 2>&1; exit" >/dev/null
