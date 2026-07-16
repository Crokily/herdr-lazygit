#!/usr/bin/env bash
# launch-stage.sh — open a dedicated Ghostty window running a named herdr
# session for demo recording, with a sanitized environment.
#
# macOS `open` propagates the caller's environment to the launched app, so a
# recording driven from an agent shell can silently inherit NO_COLOR/CLICOLOR
# and render every color-respecting TUI (lazygit/tcell, fzf, delta) in
# monochrome. Strip those plus herdr nesting vars before launching.
#
# Usage: launch-stage.sh [session-name]   (default: gifdemo)
set -euo pipefail

session="${1:-gifdemo}"
env -u NO_COLOR -u CLICOLOR -u CLICOLOR_FORCE \
    -u HERDR_ENV -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  open -na Ghostty.app --args -e herdr --session "$session"

# wait until the session registers
for _ in $(seq 1 20); do
  sock="$(herdr session list --json 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
for s in json.load(sys.stdin)["sessions"]:
    if s["name"] == name and s.get("running"):
        print(s["socket_path"]); break
' "$session")"
  [ -n "$sock" ] && break
  sleep 0.5
done
[ -n "${sock:-}" ] || { echo "launch-stage: session $session did not start" >&2; exit 1; }
printf '%s\n' "$sock"
