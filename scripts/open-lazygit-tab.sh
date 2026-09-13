#!/usr/bin/env bash
# Launch/focus/toggle lazygit with bounded commands and a workspace-scoped lock.
# Shared behavior lives in launcher.py; the action selects only the placement.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
exec python3 "$script_dir/launcher.py" tab
