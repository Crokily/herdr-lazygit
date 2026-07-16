#!/usr/bin/env bash
# choreography.sh — drive the herdr-lazygit demo deterministically over the
# herdr socket. The recording tool (screen capture) runs separately; this
# script only performs the on-screen "acting" with directed pacing.
#
# Narrative order (v2): the compact sidebar carries a complete stage->commit
# flow first (the design thesis: single-column is enough day to day), and only
# then U expands for deep diff review, followed by a settings glimpse.
#
# Usage:
#   choreography.sh <demo-repo-dir> [session-name]
#
# With a session name, the script resolves that session's socket from
# `herdr session list --json` and targets it. Without one it uses the
# current HERDR_SOCKET_PATH (default session).
#
# Env:
#   SKIP_FOCUS=1   do not switch UI focus to the demo workspace (dry runs)
#   FAST=1         cut all pauses to 0.3s (structural dry runs)
set -euo pipefail

repo="${1:?usage: choreography.sh <demo-repo-dir> [session-name]}"
session="${2:-}"

if [ -n "$session" ]; then
  sock="$(herdr session list --json | python3 -c '
import json, sys
name = sys.argv[1]
for s in json.load(sys.stdin)["sessions"]:
    if s["name"] == name and s.get("running"):
        print(s["socket_path"]); break
' "$session")"
  [ -n "$sock" ] || { echo "choreography: session $session not running" >&2; exit 1; }
  export HERDR_SOCKET_PATH="$sock"
fi

pause() {  # pause <seconds> — the pacing primitive; FAST=1 collapses it
  if [ "${FAST:-}" = "1" ]; then sleep 0.3; else sleep "$1"; fi
}

pane_json() { python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]'"$1"')'; }

# scene marks carry sub-second epochs so captions can be timed in post
say() { printf '[scene %s] %s\n' "$(python3 -c 'import time; print(f"{time.time():.2f}")')" "$1"; }

# --- stage: fresh workspace with a work pane showing code -------------------
say "stage"
create_json="$(herdr workspace create --cwd "$repo" --no-focus 2>/dev/null)"
work_pane="$(printf '%s' "$create_json" | pane_json '["root_pane"]["pane_id"]')"
ws="$(printf '%s' "$create_json" | pane_json '["root_pane"]["workspace_id"]')"
if [ "${SKIP_FOCUS:-}" != "1" ]; then
  herdr workspace focus "$ws" >/dev/null
fi
herdr pane run "$work_pane" "clear; bat --paging=never --style=numbers --color=always src/tasks.ts 2>/dev/null || cat src/tasks.ts" >/dev/null
pause 2

# --- scene 1: one key opens the sidebar --------------------------------------
say "sidebar-open"
herdr plugin pane open --plugin herdr-lazygit --entrypoint lazygit \
  --placement split --direction right --cwd "$repo" \
  --target-pane "$work_pane" --focus >/dev/null
sleep 1.2
git_pane="$(herdr pane list 2>/dev/null | python3 -c '
import json, sys
ws = sys.argv[1]
for p in json.load(sys.stdin)["result"]["panes"]:
    if p.get("workspace_id") == ws and p.get("label") == "Git":
        print(p["pane_id"]); break
' "$ws")"
python3 "$(dirname "$0")/../scripts/layout-helper.py" set-width "$git_pane" 42

# color gate: lazygit must be emitting ANSI colors, otherwise the recording
# would be monochrome (NO_COLOR & friends leaking into the session — see
# launch-stage.sh). Abort loudly instead of producing a gray demo.
if ! herdr pane read "$git_pane" --source visible --lines 10 --format ansi 2>/dev/null \
    | grep -qE $'\x1b\\[38;5;[0-9]'; then
  echo "choreography: COLOR GATE FAILED — lazygit is rendering without colors; check the session environment (NO_COLOR?)" >&2
  exit 1
fi
pause 3

# --- scene 2: stage two files, right in the sidebar ---------------------------
say "stage-files"
herdr pane send-text "$git_pane" "j"     # src dir -> notify.ts
pause 0.6
herdr pane send-text "$git_pane" "j"     # -> store.ts
pause 0.8
herdr pane send-text "$git_pane" " "     # stage store.ts (red -> staged)
pause 1.4
herdr pane send-text "$git_pane" "j"     # -> tasks.ts (works whether or not
pause 0.8                                 # lazygit auto-advanced after space)
herdr pane send-text "$git_pane" " "     # stage tasks.ts
pause 1.8

# --- scene 3: AI commit, entirely beside the narrow sidebar -------------------
say "commit-open"
herdr pane send-text "$git_pane" "C"
sleep 1.5
commit_pane="$(herdr pane list 2>/dev/null | python3 -c '
import json, sys
ws = sys.argv[1]
for p in json.load(sys.stdin)["result"]["panes"]:
    if p.get("workspace_id") == ws and p.get("label") == "GitCommit":
        print(p["pane_id"]); break
' "$ws")"
# wait for candidates: poll until the fzf prompt appears (bounded)
for _ in $(seq 1 30); do
  if herdr pane read "$commit_pane" --source visible --lines 3 2>/dev/null | grep -q "Commit message"; then
    break
  fi
  sleep 1
done
say "commit-pick"
pause 4                                        # read candidates + diff preview
herdr pane send-text "$commit_pane" $'\x1b[B'  # arrow down: preview follows
pause 2
herdr pane send-text "$commit_pane" $'\x1b[A'
pause 1.5
say "commit-done"
herdr pane send-text "$commit_pane" $'\r'      # commit the selected candidate
pause 2.5

# --- scene 4: back at the narrow sidebar — one file still unstaged ------------
say "back-narrow"
pause 3.5

# --- scene 5: U expands for deep review ---------------------------------------
say "expand"
herdr pane send-text "$git_pane" "U"
pause 2.5
say "browse"
herdr pane send-text "$git_pane" "j"     # select the remaining notify.ts
pause 3.5
say "collapse"
herdr pane send-text "$git_pane" "U"
pause 2.5

# --- scene 6: settings glimpse -------------------------------------------------
say "settings"
herdr pane send-text "$git_pane" ";"
sleep 1.5
settings_pane="$(herdr pane list 2>/dev/null | python3 -c '
import json, sys
ws = sys.argv[1]
for p in json.load(sys.stdin)["result"]["panes"]:
    if p.get("workspace_id") == ws and p.get("label") == "GitSettings":
        print(p["pane_id"]); break
' "$ws")"
pause 2
herdr pane send-text "$settings_pane" $'\x1b[B'
pause 1.2
herdr pane send-text "$settings_pane" $'\x1b[B'
pause 1.8
herdr pane send-text "$settings_pane" "q"
pause 1.2

# --- scene 7: close, end on the code ------------------------------------------
say "close"
herdr plugin pane close "$git_pane" >/dev/null 2>&1 || true
pause 3.5

say "end"
printf '%s\n' "$ws" > "${DEMO_WS_FILE:-/tmp/herdr-lazygit-demo-ws}"
