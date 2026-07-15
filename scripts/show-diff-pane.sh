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

# --- close the previous GitDiff pane, pick the widest pane as split target -
# One python call: `pane layout --pane <me>` gives every pane in this tab with
# its rect; `pane list` supplies the labels (to spot the old GitDiff pane).
plan="$(python3 - "$HERDR_TAB_ID" "$HERDR_PANE_ID" <<'PY'
import json, subprocess, sys
tab, me = sys.argv[1], sys.argv[2]

def run(*args):
    out = subprocess.run(["herdr", *args], capture_output=True, text=True)
    try:
        return json.loads(out.stdout)["result"]
    except Exception:
        return {}

labels = {p["pane_id"]: p.get("label") or ""
          for p in run("pane", "list").get("panes", [])
          if p.get("tab_id") == tab}
layout_panes = run("pane", "layout", "--pane", me).get("layout", {}).get("panes", [])

for pid, label in labels.items():
    if label == "GitDiff":
        print("CLOSE", pid)

best, best_w = None, -1
for p in layout_panes:
    pid = p["pane_id"]
    if pid == me or labels.get(pid) == "GitDiff":
        continue
    w = p.get("rect", {}).get("width", 0) or 0
    if w > best_w:
        best, best_w = pid, w
if best:
    print("SPLIT", best, "right")
else:
    print("SPLIT", me, "down")  # sidebar alone in its tab: stack the diff below
PY
)"

split_target="" ; split_dir="down"
while read -r verb a b; do
  case "$verb" in
    CLOSE) herdr pane close "$a" >/dev/null 2>&1 || true ;;
    SPLIT) split_target="$a"; split_dir="$b" ;;
  esac
done <<EOF
$plan
EOF
[ -n "$split_target" ] || { echo "show-diff-pane.sh: no split target" >&2; exit 1; }

# --- open the pane and run the diff ----------------------------------------
new_pane="$(herdr pane split --pane "$split_target" --direction "$split_dir" --ratio 0.5 --focus 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
[ -n "$new_pane" ] || { echo "show-diff-pane.sh: pane split failed" >&2; exit 1; }

herdr pane rename "$new_pane" "GitDiff" >/dev/null 2>&1 || true
# "; exit" makes quitting the pager close the pane itself
herdr pane run "$new_pane" "clear; $view_cmd; exit" >/dev/null
