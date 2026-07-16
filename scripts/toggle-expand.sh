#!/usr/bin/env bash
# toggle-expand.sh — KEY_ZOOM 的 handler:展开/收起 lazygit 本体。
#
# LAYOUT_MODE 持久化在 panel.conf;每次切换后重生成 generated.yml 的 gui 段,
# 调整当前 lazygit pane 的绝对宽度,最后注入 CSI focus-in 让 lazygit 立即
# 热重载配置。脚本由 lazygit customCommand 调用,HERDR_PANE_ID 就是本 pane。
#
# bash 3.2 兼容(macOS 默认)。
set -euo pipefail

[ "${HERDR_ENV:-}" = "1" ] || { echo "toggle-expand.sh: not inside herdr" >&2; exit 1; }
[ -n "${HERDR_PANE_ID:-}" ] || { echo "toggle-expand.sh: HERDR_PANE_ID is empty" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
helper="$script_dir/layout-helper.py"
config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
panel_conf="$config_dir/panel.conf"

SIDEBAR_COLS=42
EXPAND_COLS=110
LAYOUT_MODE=sidebar
# shellcheck disable=SC1090
[ -f "$panel_conf" ] && . "$panel_conf"

case "$SIDEBAR_COLS" in *[!0-9]*|'') SIDEBAR_COLS=42 ;; esac
case "$EXPAND_COLS" in *[!0-9]*|'') EXPAND_COLS=110 ;; esac
[ "$SIDEBAR_COLS" -ge 20 ] 2>/dev/null || SIDEBAR_COLS=42
[ "$EXPAND_COLS" -ge 80 ] 2>/dev/null || EXPAND_COLS=80
case "$LAYOUT_MODE" in sidebar|expanded) ;; *) LAYOUT_MODE=sidebar ;; esac

# 保留 panel.conf 里的其他设置,只原子更新 LAYOUT_MODE。
write_layout_mode() {
  local mode="$1" tmp
  mkdir -p "$config_dir"
  tmp="$(mktemp "${TMPDIR:-/tmp}/herdr-lazygit.panel.XXXXXX")"
  if [ -f "$panel_conf" ]; then
    grep -v '^LAYOUT_MODE=' "$panel_conf" > "$tmp" || true
  else
    printf '%s\n' '# panel.conf — herdr-lazygit 面板几何与布局状态。' > "$tmp"
  fi
  printf "LAYOUT_MODE='%s'\n" "$mode" >> "$tmp"
  mv "$tmp" "$panel_conf"
}

if [ "$LAYOUT_MODE" = "sidebar" ]; then
  next_mode="expanded"
  target_cols="$EXPAND_COLS"

  # 展开后仍给 tab 的其他工作区保留至少 20 列。正常 tab(>=100 列)同时
  # 保证 lazygit 不低于 80 列;更窄时两条约束不可同时满足,优先保留工作区。
  tab_width="$(herdr pane layout --pane "$HERDR_PANE_ID" 2>/dev/null | python3 -c '
import json, sys
try:
    print(int(json.load(sys.stdin)["result"]["layout"]["area"]["width"]))
except Exception:
    print(0)
' || echo 0)"
  case "$tab_width" in *[!0-9]*|'') tab_width=0 ;; esac
  if [ "$tab_width" -gt 20 ]; then
    max_cols=$((tab_width - 20))
    [ "$target_cols" -le "$max_cols" ] || target_cols="$max_cols"
  fi
else
  next_mode="sidebar"
  target_cols="$SIDEBAR_COLS"
fi

write_layout_mode "$next_mode"
HERDR_PLUGIN_CONFIG_DIR="$config_dir" bash "$script_dir/gen-config-layer.sh"
python3 "$helper" set-width "$HERDR_PANE_ID" "$target_cols"

# lazygit 在 focus-in 时 stat 并热重载全部配置;直接注入事件即可立即切布局。
herdr pane send-text "$HERDR_PANE_ID" $'\x1b[I' >/dev/null
