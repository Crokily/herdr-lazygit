#!/usr/bin/env bash
# Read shell-sourceable preferences in a bounded child of launcher.py.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$script_dir/runtime-env.sh"
herdr_lazygit_require_runtime lazygit
herdr_lazygit_version_notice
. "$script_dir/layout-layer.sh"
herdr_lazygit_load_launch_preferences "$HERDR_LAZYGIT_CONFIG_DIR/panel.conf" "${1:-split}"
printf '%s\0' "$HERDR_LAZYGIT_INITIAL_MODE" "$HERDR_LAZYGIT_INITIAL_COLS"
