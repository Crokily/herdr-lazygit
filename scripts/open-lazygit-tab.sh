#!/usr/bin/env bash
# Idempotent launcher for lazygit in its own TAB — used by the `open-tab`
# action. "Open-or-switch, toggle on repeat", scoped across the tabs of the
# CURRENT WORKSPACE (mirrors herdr-file-viewer's tab launcher pattern):
#   - no lazygit pane in this workspace          -> open lazygit in a new tab (focused)
#   - a lazygit pane in another tab here         -> switch to that tab (no duplicate)
#   - a lazygit pane in the current tab,
#     but not focused                            -> focus it in place
#   - the focused pane IS the lazygit pane       -> close it (toggle off)
# A lazygit pane in a DIFFERENT workspace is left alone and a fresh one opens
# here — the action never switches you across workspaces.
#
# Sibling of scripts/open-lazygit.sh (the split variant); pane identification
# (title "Git" + foreground-process check + same-target identity),
# degradation to OPEN on any failure, cwd resolution, and the
# HERDR_LAZYGIT_TEST_DECISION test hook all match it.
#
# bash 3.2 compatible (macOS default); JSON handled with python3, not jq.
set -euo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"

# --- runtime precheck --------------------------------------------------------
# Same as open-lazygit.sh: surface a missing/broken runtime in the action's
# stderr (captured by `herdr plugin log list`) instead of an instantly-dying pane.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/runtime-env.sh"
herdr_lazygit_require_runtime lazygit || exit 1
herdr_lazygit_version_notice || true

# --- serialize concurrent launcher runs -------------------------------------
# Same locking as open-lazygit.sh (see the comment there): action invokes are
# fire-and-forget, so rapid repeats race the snapshot-then-act logic below.
# The lock file is SHARED with open-lazygit.sh — both mutate the same lazygit
# pane state. Held across `exec` until the final herdr command exits.
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

open_tab() {
  exec "$herdr_bin" plugin pane open \
    --plugin herdr-lazygit \
    --entrypoint lazygit \
    --placement tab \
    --cwd "$target_dir" \
    --focus
}

# --- compute the OPEN/SWITCHTAB/FOCUS/CLOSE decision ------------------------
panes_json="$("$herdr_bin" pane list 2>/dev/null || true)"
current_json="$("$herdr_bin" pane current 2>/dev/null || true)"

decision="$(HERDR_PANES_JSON="$panes_json" HERDR_CURRENT_JSON="$current_json" \
  HERDR_BIN="$herdr_bin" HERDR_TARGET_DIR="$target_dir" python3 - <<'PY' || echo OPEN
import json, os, re, subprocess, sys, time

SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_-]*$")  # option-injection guard for ids
herdr = os.environ.get("HERDR_BIN") or "herdr"
target_dir = os.environ.get("HERDR_TARGET_DIR") or ""

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

def normalize_dir(path):
    if not isinstance(path, str) or not path:
        return None
    try:
        resolved = os.path.realpath(path)
    except Exception:
        return None
    return resolved if os.path.isdir(resolved) else None

def resolve_identity(path):
    resolved = normalize_dir(path)
    if not resolved:
        return None
    try:
        top = subprocess.run(
            ["git", "-C", resolved, "rev-parse", "--show-toplevel"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5,
        )
    except Exception:
        return None
    if top.returncode == 0:
        top_dir = normalize_dir((top.stdout or "").strip())
        if top_dir:
            return {"kind": "worktree", "value": top_dir}
        return None
    try:
        git_dir = subprocess.run(
            ["git", "-C", resolved, "rev-parse", "--absolute-git-dir"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5,
        )
    except Exception:
        return None
    if git_dir.returncode == 0:
        bare_dir = normalize_dir((git_dir.stdout or "").strip())
        if bare_dir:
            return {"kind": "bare", "value": bare_dir}
        return None
    return {"kind": "dir", "value": resolved}

def resolve_pane_identity(pane):
    for key in ("foreground_cwd", "cwd"):
        value = pane.get(key)
        if not isinstance(value, str) or not value:
            continue
        identity = resolve_identity(value)
        if identity:
            return identity
    return None

def same_identity(a, b):
    if not a or not b:
        return False
    return a["kind"] == b["kind"] and a["value"] == b["value"]

candidates = [
    p for p in panes
    if isinstance(p, dict)
    and p.get("workspace_id") == cur.get("workspace_id")
    and p.get("label") == "Git"
    and SAFE.match(p.get("pane_id") or "")
    and SAFE.match(p.get("tab_id") or "")
]

target_identity = resolve_identity(target_dir)
pane_identity_cache = {}

def matches_target(pane):
    if not target_identity:
        return False
    pane_id = pane.get("pane_id") or ""
    if pane_id not in pane_identity_cache:
        pane_identity_cache[pane_id] = resolve_pane_identity(pane)
    return same_identity(target_identity, pane_identity_cache[pane_id])

# A pane freshly created by a just-finished `plugin pane open` can exist while
# lazygit has not started yet, so a "Git" candidate that fails the process
# check is re-checked briefly before we conclude it is not ours.
attempts = 4 if candidates else 1
for i in range(attempts):
    matches = [p for p in candidates if runs_lazygit(p["pane_id"])]
    matches = [p for p in matches if matches_target(p)]
    if matches:
        # Prefer a match in the current tab (focus/toggle in place) over a
        # cross-tab switch; among current-tab duplicates prefer the focused
        # one, so a toggle press always closes the pane the user is in.
        in_tab = [p for p in matches if p.get("tab_id") == cur.get("tab_id")]
        for p in in_tab:
            if p.get("focused"):
                emit("CLOSE " + p["pane_id"])
        if in_tab:
            emit("FOCUS " + in_tab[0]["pane_id"])
        emit("SWITCHTAB " + matches[0]["tab_id"])
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
  "SWITCHTAB "*)
    tid="${decision#SWITCHTAB }"
    # If the target tab vanished between the snapshot and now (a race), fall
    # back to opening a fresh lazygit tab rather than a silent no-op.
    "$herdr_bin" tab focus "$tid" || open_tab
    ;;
  "FOCUS "*)
    pid="${decision#FOCUS }"
    exec "$herdr_bin" plugin pane focus "$pid"
    ;;
  "CLOSE "*)
    pid="${decision#CLOSE }"
    exec "$herdr_bin" plugin pane close "$pid"
    ;;
  *)
    open_tab
    ;;
esac
