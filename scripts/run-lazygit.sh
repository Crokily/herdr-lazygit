#!/usr/bin/env bash
# Pane entrypoint: assemble the layered lazygit configuration, then exec lazygit.
#
# Config layering (verified against lazygit's docs/Config.md: LG_CONFIG_FILE
# accepts a comma-separated list of config files, later files merged over
# earlier ones):
#   1. $PLUGIN_ROOT/lazygit-config.yml           — the plugin's bundled config
#      (customCommands for AI commit messages, etc.)
#   2. $HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml — the user's override layer,
#      created empty (comments only) on first run; survives plugin updates.
#
# HERDR_LAZYGIT_ROOT is exported so the bundled config's customCommands can
# locate the plugin's scripts (e.g. scripts/ai-commit-msg.sh) by absolute path.
#
# bash 3.2 compatible (macOS default).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "$script_dir/.." && pwd)"
export HERDR_LAZYGIT_ROOT="$PLUGIN_ROOT"

# herdr injects HERDR_PLUGIN_CONFIG_DIR for plugin panes; fall back to a
# sensible per-user dir so the script also works when run outside herdr.
config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
mkdir -p "$config_dir"

user_config="$config_dir/lazygit-user.yml"
if [ ! -f "$user_config" ]; then
  cat > "$user_config" <<'EOF'
# lazygit-user.yml — your personal override layer for the herdr-lazygit plugin.
#
# Settings here are merged OVER the plugin's bundled lazygit-config.yml
# (lazygit merges the comma-separated LG_CONFIG_FILE list left to right).
# Add any lazygit config keys you want to customize, e.g.:
#
#   gui:
#     nerdFontsVersion: "3"
#
# Full reference: https://github.com/jesseduffield/lazygit/blob/master/docs/Config.md
EOF
fi

export LG_CONFIG_FILE="$PLUGIN_ROOT/lazygit-config.yml,$user_config"
exec lazygit
