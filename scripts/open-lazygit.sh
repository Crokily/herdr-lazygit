#!/usr/bin/env bash
# Idempotent launcher for the lazygit pane — used by the `open` action and any
# herdr keybinding pointing at it. "Launch-or-focus, toggle on repeat", scoped
# to the CURRENT TAB (mirrors herdr-file-viewer's launcher pattern):
#   - no lazygit pane in the current tab      -> open a split (focused)
#   - a lazygit pane exists but isn't focused -> focus it
#   - the focused pane IS the lazygit pane    -> close it (toggle off)
#
# Our pane is identified by its manifest title ("Git") plus a foreground
# process check (`herdr pane process-info`) confirming lazygit actually runs
# there — a user's own pane merely labeled "Git" is left alone. Any failure
# (herdr CLI error, JSON parse error) degrades to OPEN.
#
# The pane's initial cwd comes from HERDR_PLUGIN_CONTEXT_JSON:
# focused_pane_cwd, else workspace_cwd, else $HOME.
#
# bash 3.2 compatible (macOS default); JSON handled with python3, not jq.
#
# Test hook: HERDR_LAZYGIT_TEST_DECISION=1 prints the computed decision and
# target dir instead of acting on them (used by pure-shell self-tests with a
# fake HERDR_BIN_PATH).
set -euo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"

# --- resolve the directory the pane should open in -------------------------
target_dir="$(python3 - <<'PY'
import json, os
d = ""
raw = os.environ.get("HERDR_PLUGIN_CONTEXT_JSON") or ""
try:
    ctx = json.loads(raw)
    if isinstance(ctx, dict):
        for key in ("focused_pane_cwd", "workspace_cwd"):
            v = ctx.get(key)
            if isinstance(v, str) and v:
                d = v
                break
except Exception:
    d = ""
print(d or os.environ.get("HOME") or os.getcwd())
PY
)"

open_pane() {
  exec "$herdr_bin" plugin pane open \
    --plugin herdr-lazygit \
    --entrypoint lazygit \
    --placement split \
    --direction right \
    --cwd "$target_dir" \
    --focus
}

# --- compute the OPEN/FOCUS/CLOSE decision ----------------------------------
panes_json="$("$herdr_bin" pane list 2>/dev/null || true)"
current_json="$("$herdr_bin" pane current 2>/dev/null || true)"

decision="$(HERDR_PANES_JSON="$panes_json" HERDR_CURRENT_JSON="$current_json" \
  HERDR_BIN="$herdr_bin" python3 - <<'PY' || echo OPEN
import json, os, re, subprocess, sys

SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_-]*$")  # option-injection guard for ids
herdr = os.environ.get("HERDR_BIN") or "herdr"

def emit(s):
    print(s)
    sys.exit(0)

try:
    panes = json.loads(os.environ.get("HERDR_PANES_JSON") or "")["result"]["panes"]
    cur = json.loads(os.environ.get("HERDR_CURRENT_JSON") or "")["result"]["pane"]
except Exception:
    emit("OPEN")

def runs_lazygit(pane_id):
    try:
        r = subprocess.run(
            [herdr, "pane", "process-info", "--pane", pane_id],
            capture_output=True, text=True, timeout=5,
        )
        info = json.loads(r.stdout)["result"]["process_info"]
        for p in info.get("foreground_processes") or []:
            name = (p.get("name") or "") + " " + (p.get("argv0") or "")
            if "lazygit" in name:
                return True
    except Exception:
        pass
    return False

for p in panes:
    if not isinstance(p, dict):
        continue
    pid = p.get("pane_id") or ""
    if p.get("workspace_id") != cur.get("workspace_id"):
        continue
    if p.get("tab_id") != cur.get("tab_id"):
        continue
    if p.get("label") != "Git" or not SAFE.match(pid):
        continue
    if not runs_lazygit(pid):
        continue
    emit(("CLOSE " if p.get("focused") else "FOCUS ") + pid)
print("OPEN")
PY
)"

if [ "${HERDR_LAZYGIT_TEST_DECISION:-}" = "1" ]; then
  printf '%s\n' "$decision"
  printf 'DIR %s\n' "$target_dir"
  exit 0
fi

case "$decision" in
  "FOCUS "*)
    pid="${decision#FOCUS }"
    exec "$herdr_bin" plugin pane focus "$pid"
    ;;
  "CLOSE "*)
    pid="${decision#CLOSE }"
    exec "$herdr_bin" plugin pane close "$pid"
    ;;
  *)
    open_pane
    ;;
esac
