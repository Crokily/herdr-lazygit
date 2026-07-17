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

# --- runtime precheck --------------------------------------------------------
# Fail fast — and visibly in `herdr plugin log list`, which captures action
# stderr — when the runtime is missing or a panel.conf override points at a
# broken binary. Without this the pane opens and dies instantly with its error
# unreadable.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/runtime-env.sh"
herdr_lazygit_require_runtime lazygit || exit 1
herdr_lazygit_version_notice || true

# --- serialize concurrent launcher runs -------------------------------------
# `herdr plugin action invoke` is fire-and-forget (returns while the action is
# still "running"), so even two back-to-back invokes (key auto-repeat, double
# keypress) run concurrently server-side. Without a lock both snapshot the
# same pane state and both act on it: two OPENs -> duplicate lazygit panes,
# or two CLOSEs -> one plugin_pane_not_found failure. Take an exclusive flock
# BEFORE snapshotting; the fd is inherited across `exec`, so the lock is held
# until this launcher's final herdr command exits and the next invoke then
# sees the updated state. The lock file is shared with open-lazygit-tab.sh
# (both mutate the same lazygit pane state). If the lock cannot be acquired
# within 10s, another invoke is wedged — dropping this (duplicate) invoke is
# safer than racing it. If the lock file cannot be created, degrade to the
# old unlocked behavior.
lock_file="${TMPDIR:-/tmp}/herdr-lazygit-launcher.lock"
if ( : >>"$lock_file" ) 2>/dev/null; then
  exec 9>>"$lock_file"
  python3 -c '
import fcntl, sys, time
deadline = time.time() + 10.0
while True:
    try:
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except OSError:
        if time.time() >= deadline:
            sys.exit(1)
        time.sleep(0.05)
' || exit 0
fi

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

# Sidebar width in columns; override via $HERDR_PLUGIN_CONFIG_DIR/panel.conf
SIDEBAR_COLS=42
panel_conf="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}/panel.conf"
# shellcheck disable=SC1090
[ -f "$panel_conf" ] && . "$panel_conf"

open_pane() {
  local resp pane_id script_dir
  resp="$("$herdr_bin" plugin pane open \
    --plugin herdr-lazygit \
    --entrypoint lazygit \
    --placement split \
    --direction right \
    --cwd "$target_dir" \
    --focus 2>/dev/null || true)"
  # narrow the fresh split down to a single-column sidebar
  pane_id="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["result"]["plugin_pane"]["pane"]["pane_id"])
except Exception:
    pass' || true)"
  if [ -n "$pane_id" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    python3 "$script_dir/layout-helper.py" set-width "$pane_id" "$SIDEBAR_COLS" 2>/dev/null || true
  fi
  exit 0
}

# --- compute the OPEN/FOCUS/CLOSE decision ----------------------------------
panes_json="$("$herdr_bin" pane list 2>/dev/null || true)"
current_json="$("$herdr_bin" pane current 2>/dev/null || true)"

decision="$(HERDR_PANES_JSON="$panes_json" HERDR_CURRENT_JSON="$current_json" \
  HERDR_BIN="$herdr_bin" python3 - <<'PY' || echo OPEN
import json, os, re, subprocess, sys, time

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

candidates = [
    p for p in panes
    if isinstance(p, dict)
    and p.get("workspace_id") == cur.get("workspace_id")
    and p.get("tab_id") == cur.get("tab_id")
    and p.get("label") == "Git"
    and SAFE.match(p.get("pane_id") or "")
]

# A pane freshly created by a just-finished `plugin pane open` can exist while
# lazygit has not started yet, so a "Git" candidate that fails the process
# check is re-checked briefly before we conclude it is not ours (only costs
# time when a Git-labeled pane fails the check — the common no-pane and
# running-pane cases are unaffected).
attempts = 4 if candidates else 1
for i in range(attempts):
    matches = [p for p in candidates if runs_lazygit(p["pane_id"])]
    if matches:
        # Prefer the focused match: with duplicates, first-match-wins would
        # FOCUS a sibling instead of toggling the focused pane closed.
        for p in matches:
            if p.get("focused"):
                emit("CLOSE " + p["pane_id"])
        emit("FOCUS " + matches[0]["pane_id"])
    if i + 1 < attempts:
        time.sleep(0.3)
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
