#!/usr/bin/env bash
# Hermetic tests for per-pane layout-state isolation: startup creates a
# pane-local lazygit layer, stale layout files are cleaned up, and KEY_ZOOM
# rewrites only that per-pane file instead of global panel.conf/generated.yml.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/herdr-lazygit-layout-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

stub="$tmp/stub-lazygit"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --print-config-dir) printf '%s\n' "${FAKE_USER_DIR:-}" ;;
  --version) printf 'commit=x, build date=x, build source=binaryRelease, version=%s, os=darwin, arch=arm64, git version=2.50.1 (Apple Git-155)\n' "${FAKE_VERSION:-0.63.0}" ;;
  *)
    printf 'STUB_LG_CONFIG_FILE=%s\n' "${LG_CONFIG_FILE:-}"
    printf 'STUB_LAYOUT_FILE=%s\n' "${HERDR_LAZYGIT_LAYOUT_FILE:-}"
    ;;
esac
EOF
chmod 0755 "$stub"

fake_helper="$tmp/fake-layout-helper.py"
cat > "$fake_helper" <<'EOF'
import os
import sys

with open(os.environ["FAKE_LAYOUT_HELPER_LOG"], "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
EOF

fake_herdr="$tmp/fake-herdr"
cat > "$fake_herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "pane layout")
    printf '%s\n' '{"result":{"layout":{"area":{"width":160}}}}'
    ;;
  "pane send-text")
    printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
    ;;
  *)
    printf 'unexpected fake herdr command: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod 0755 "$fake_herdr"

run_pane() {
  local conf="$1"; shift
  mkdir -p "$conf"
  env HOME="$tmp/home" FAKE_USER_DIR="$tmp/no-user-config" HERDR_LAZYGIT_BIN="$stub" \
    HERDR_PLUGIN_ROOT="$repo_root" HERDR_PLUGIN_CONFIG_DIR="$conf" "$@" \
    bash "$repo_root/scripts/run-lazygit.sh" </dev/null
}

layout_from_output() {
  printf '%s\n' "$1" | sed -n 's/^STUB_LAYOUT_FILE=//p'
}

# ---------------------------------------------------------------------------
# Startup removes dead layout-* files, preserves live ones, and creates a new
# sidebar layer for the current pane.
# ---------------------------------------------------------------------------
cleanup_conf="$tmp/conf-cleanup"
mkdir -p "$cleanup_conf"
printf "SIDEBAR_COLS=44\n" > "$cleanup_conf/panel.conf"
live_layout="$cleanup_conf/layout-$$-111.yml"
dead_pid=999999
kill -0 "$dead_pid" 2>/dev/null && dead_pid=888888
dead_layout="$cleanup_conf/layout-$dead_pid-222.yml"
printf 'keep\n' > "$live_layout"
printf 'remove\n' > "$dead_layout"

out="$(run_pane "$cleanup_conf" 2>/dev/null)"
layout_file="$(layout_from_output "$out")"
[ -f "$layout_file" ]
[ -e "$live_layout" ]
[ ! -e "$dead_layout" ]
grep -q '^# layout: sidebar$' "$layout_file"
grep -q '^  sidePanelWidth: 0.99$' "$layout_file"

# ---------------------------------------------------------------------------
# KEY_ZOOM rewrites only the pane-local layout file. panel.conf stays global
# and generated.yml stays global/static.
# ---------------------------------------------------------------------------
toggle_conf="$tmp/conf-toggle"
mkdir -p "$toggle_conf"
cat > "$toggle_conf/panel.conf" <<'EOF'
INHERIT_USER_CONFIG=0
SIDEBAR_COLS=50
EXPAND_COLS=120
EOF

out="$(run_pane "$toggle_conf" 2>/dev/null)"
layout_file="$(layout_from_output "$out")"
generated="$toggle_conf/generated.yml"
[ -f "$generated" ]
if grep -q '^gui:' "$generated"; then
  echo "generated.yml should no longer contain pane-local gui layout state" >&2
  cat "$generated" >&2
  exit 1
fi

before_panel="$(cat "$toggle_conf/panel.conf")"
before_generated="$(cat "$generated")"
helper_log="$tmp/helper.log"
herdr_log="$tmp/herdr.log"
: > "$helper_log"
: > "$herdr_log"

toggle_env=(
  HERDR_ENV=1
  HERDR_PANE_ID=test-pane
  HERDR_BIN_PATH="$fake_herdr"
  HERDR_PLUGIN_CONFIG_DIR="$toggle_conf"
  HERDR_LAZYGIT_LAYOUT_FILE="$layout_file"
  HERDR_LAZYGIT_LAYOUT_HELPER="$fake_helper"
  FAKE_LAYOUT_HELPER_LOG="$helper_log"
  FAKE_HERDR_LOG="$herdr_log"
)

env "${toggle_env[@]}" bash "$repo_root/scripts/toggle-expand.sh"
grep -q '^# layout: expanded$' "$layout_file"
grep -q '^  sidePanelWidth: 0.3333$' "$layout_file"
grep -q '^set-width test-pane 120$' "$helper_log"
grep -q '^pane send-text test-pane ' "$herdr_log"
[ "$before_panel" = "$(cat "$toggle_conf/panel.conf")" ]
[ "$before_generated" = "$(cat "$generated")" ]
if grep -q '^LAYOUT_MODE=' "$toggle_conf/panel.conf"; then
  echo "panel.conf should not gain LAYOUT_MODE during toggle" >&2
  cat "$toggle_conf/panel.conf" >&2
  exit 1
fi

env "${toggle_env[@]}" bash "$repo_root/scripts/toggle-expand.sh"
grep -q '^# layout: sidebar$' "$layout_file"
grep -q '^  sidePanelWidth: 0.99$' "$layout_file"
grep -q '^set-width test-pane 50$' "$helper_log"

printf 'layout isolation tests passed\n'
