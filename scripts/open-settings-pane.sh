#!/usr/bin/env bash
# open-settings-pane.sh — KEY_SETTINGS 的 handler:在 herdr 里打开插件设置页。
# 由 lazygit 的 customCommand(生成层 generated.yml)从 lazygit pane 内触发,
# 所以 HERDR_PANE_ID / HERDR_TAB_ID 指向侧栏 pane。
#
# 行为(与 open-ai-commit-pane.sh 的几何模式同构):
#   - 先关掉本 tab 里旧的 "GitSettings" pane(单实例)
#   - 在侧栏右侧 split 出设置 pane,layout-helper.py place-diff 把
#     (侧栏|设置) 区域摆成 SIDEBAR_COLS + SETTINGS_COLS 列
#   - pane 内运行 settings-fzf.sh;退出(Esc/q)时 set-region-width 恢复
#     打开前的 sidebar/expanded 宽度,再 exit 关掉 pane
#
# bash 3.2 兼容(macOS 默认)。
set -euo pipefail

[ "${HERDR_ENV:-}" = "1" ] || { echo "open-settings-pane.sh: not inside herdr" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
helper="$script_dir/layout-helper.py"
settings_sh="$script_dir/settings-fzf.sh"

# 引号安全:bash 3.2 的 printf %q 会把多字节
# UTF-8(如中文路径)拆成非法字节序列,herdr CLI(Rust)收到会 panic。
# 统一用 python3 shlex.quote:单引号包裹、原始 UTF-8 原样保留。
shq() { python3 -c 'import shlex, sys; sys.stdout.write(shlex.quote(sys.argv[1]))' "$1"; }

# --- 几何参数:默认侧栏 42 列 / 设置页 70 列,panel.conf 可覆盖 -------------
SIDEBAR_COLS=42
EXPAND_COLS=110
SETTINGS_COLS=70
LAYOUT_MODE=sidebar
config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
panel_conf="$config_dir/panel.conf"
# shellcheck disable=SC1090
[ -f "$panel_conf" ] && . "$panel_conf"
case "$SIDEBAR_COLS" in *[!0-9]*|'') SIDEBAR_COLS=42 ;; esac
case "$EXPAND_COLS" in *[!0-9]*|'') EXPAND_COLS=110 ;; esac
case "$SETTINGS_COLS" in *[!0-9]*|'') SETTINGS_COLS=70 ;; esac
[ "$SIDEBAR_COLS" -ge 20 ] 2>/dev/null || SIDEBAR_COLS=42
[ "$EXPAND_COLS" -ge 80 ] 2>/dev/null || EXPAND_COLS=80
[ "$SETTINGS_COLS" -ge 40 ] 2>/dev/null || SETTINGS_COLS=70

# 设置 pane 显示期间 lazygit 暂时按侧栏宽度摆放;退出时恢复触发前模式。
restore_cols="$SIDEBAR_COLS"
if [ "$LAYOUT_MODE" = "expanded" ]; then
  restore_cols="$EXPAND_COLS"
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
    [ "$restore_cols" -le "$max_cols" ] || restore_cols="$max_cols"
  fi
fi

# --- 单实例:关掉本 tab 里旧的 GitSettings pane ------------------------------
panes_json="$(herdr pane list 2>/dev/null || true)"
printf '%s' "$panes_json" | python3 -c '
import json, sys
tab = sys.argv[1]
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    panes = []
for p in panes:
    if p.get("tab_id") == tab and p.get("label") == "GitSettings":
        print(p["pane_id"])
' "$HERDR_TAB_ID" | while read -r old; do herdr pane close "$old" >/dev/null 2>&1 || true; done

# --- 打开设置 pane 并摆好几何 ------------------------------------------------
new_pane="$(herdr pane split --pane "$HERDR_PANE_ID" --direction right --ratio 0.5 --focus 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
[ -n "$new_pane" ] || { echo "open-settings-pane.sh: pane split failed" >&2; exit 1; }

herdr pane rename "$new_pane" "GitSettings" >/dev/null 2>&1 || true
python3 "$helper" place-diff "$HERDR_PANE_ID" "$new_pane" "$SIDEBAR_COLS" "$SETTINGS_COLS" 2>/dev/null || true

# 退出前把 lazygit 宽度还原;settings-fzf.sh 报错(如缺 fzf)时 sleep 让提示可读;
# 末尾 exit 让 q/Esc 退出后 pane 直接消失
restore_cmd="python3 $(shq "$helper") set-region-width $(shq "$HERDR_PANE_ID") $(shq "$restore_cols")"
# 显式把配置目录传进新 pane:pane run 起的是全新 shell,不继承 lazygit
# (插件 pane)的 HERDR_PLUGIN_CONFIG_DIR——不传的话设置页会写到回退目录,
# 而 lazygit 读的是插件配置目录,改动永远不生效。
if ! herdr pane run "$new_pane" "clear; HERDR_PLUGIN_CONFIG_DIR=$(shq "$config_dir") bash $(shq "$settings_sh") || sleep 4; $restore_cmd >/dev/null 2>&1; exit" >/dev/null; then
  # run 失败会留下一个空 shell pane:收掉并把侧栏还原,不给用户留残骸
  herdr pane close "$new_pane" >/dev/null 2>&1 || true
  python3 "$helper" set-region-width "$HERDR_PANE_ID" "$restore_cols" >/dev/null 2>&1 || true
  echo "open-settings-pane.sh: pane run failed" >&2
  exit 1
fi
