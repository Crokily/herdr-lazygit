#!/usr/bin/env bash
# Regression tests for runtime path propagation and generated-config caching.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/herdr-lazygit-integration-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------
# Fresh pane commands must preserve HERDR_BIN_PATH for their cleanup helpers.
# ---------------------------------------------------------------------------
fake_herdr="$tmp/custom-herdr"
command_log="$tmp/pane-run.log"
cat > "$fake_herdr" <<'EOF'
#!/bin/sh
set -eu
case "${1:-} ${2:-}" in
  "pane list")
    printf '%s\n' '{"result":{"panes":[]}}'
    ;;
  "pane split")
    printf '%s\n' '{"result":{"pane":{"pane_id":"test-pane"}}}'
    ;;
  "pane layout")
    printf '%s\n' '{"result":{"layout":{"area":{"width":160}}}}'
    ;;
  "pane run")
    printf '%s\n' "${4:-}" >> "$FAKE_PANE_RUN_LOG"
    ;;
  "pane rename"|"pane close"|"pane send-text")
    ;;
  *)
    printf 'unexpected fake herdr command: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_herdr"
: > "$command_log"

common_env=(
  HERDR_ENV=1
  HERDR_WORKSPACE_ID=test-workspace
  HERDR_TAB_ID=test-tab
  HERDR_PANE_ID=test-origin
  HERDR_BIN_PATH="$fake_herdr"
  HERDR_PLUGIN_CONFIG_DIR="$tmp/config"
  HERDR_SOCKET_PATH="$tmp/nonexistent.sock"
  FAKE_PANE_RUN_LOG="$command_log"
)

env "${common_env[@]}" bash "$repo_root/scripts/open-settings-pane.sh"
env "${common_env[@]}" bash "$repo_root/scripts/open-ai-commit-pane.sh"
[ "$(wc -l < "$command_log" | tr -d ' ')" = 2 ]
while IFS= read -r pane_command; do
  case "$pane_command" in
    *"export HERDR_BIN_PATH=$fake_herdr "*) ;;
    *)
      printf 'pane command did not export HERDR_BIN_PATH: %s\n' "$pane_command" >&2
      exit 1
      ;;
  esac
done < "$command_log"

# ---------------------------------------------------------------------------
# Rebuilding the pinned lazygit binary must invalidate generated.yml even when
# keys and layout stay unchanged, because built-in key conflicts may differ.
# ---------------------------------------------------------------------------
runtime_root="$tmp/runtime-root"
runtime_bin="$runtime_root/bin"
config_dir="$tmp/generated-config"
mkdir -p "$runtime_bin" "$config_dir"

write_fake_lazygit() {
  local conflict_key=$1
  cat > "$runtime_bin/lazygit" <<EOF
#!/bin/sh
cat <<'CONFIG'
keybinding:
    universal:
        quit: q
    files:
        testAction: $conflict_key
CONFIG
EOF
  chmod +x "$runtime_bin/lazygit"
}

write_fake_lazygit ';'
HERDR_LAZYGIT_ROOT="$runtime_root" HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
  bash "$repo_root/scripts/gen-config-layer.sh"
grep -q 'testAction: <disabled>' "$config_dir/generated.yml"

# Ensure -nt observes a newer binary even on filesystems with second precision.
sleep 1
write_fake_lazygit X
HERDR_LAZYGIT_ROOT="$runtime_root" HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
  bash "$repo_root/scripts/gen-config-layer.sh"
if grep -q 'testAction: <disabled>' "$config_dir/generated.yml"; then
  echo 'generated.yml retained a stale lazygit key conflict' >&2
  exit 1
fi
grep -q '| lazygit: 0.63.0$' "$config_dir/generated.yml"

printf 'runtime integration tests passed\n'
