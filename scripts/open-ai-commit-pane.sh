#!/usr/bin/env bash
# open-ai-commit-pane.sh — KEY_COMMIT 的 handler:打开 AI commit 编辑 pane。
#
# 由 lazygit 的 files customCommand 触发。行为与设置 pane 同构:
#   - 本 tab 的 GitCommit 单实例
#   - 侧栏右边打开 COMMIT_COLS 宽 pane
#   - 显式传递配置目录与仓库 cwd 给新 shell
#   - UI 退出前恢复触发时的 sidebar/expanded 宽度,随后 exit 自动关 pane
#
# bash 3.2 兼容(macOS 默认)。
set -euo pipefail

[ "${HERDR_ENV:-}" = "1" ] || { echo "open-ai-commit-pane.sh: not inside herdr" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
helper="$script_dir/layout-helper.py"
commit_sh="$script_dir/ai-commit-pane.sh"
repo="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "open-ai-commit-pane.sh: not inside a git repository" >&2
  exit 1
}

# bash 3.2 的 printf %q 会破坏多字节 UTF-8;所有 pane run 命令片段统一
# 由 python3 shlex.quote 生成。
shq() { python3 -c 'import shlex, sys; sys.stdout.write(shlex.quote(sys.argv[1]))' "$1"; }

# --- 几何参数 ---------------------------------------------------------------
SIDEBAR_COLS=42
EXPAND_COLS=110
COMMIT_COLS=70
LAYOUT_MODE=sidebar
config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
panel_conf="$config_dir/panel.conf"
# shellcheck disable=SC1090
[ -f "$panel_conf" ] && . "$panel_conf"
case "$SIDEBAR_COLS" in *[!0-9]*|'') SIDEBAR_COLS=42 ;; esac
case "$EXPAND_COLS" in *[!0-9]*|'') EXPAND_COLS=110 ;; esac
case "$COMMIT_COLS" in *[!0-9]*|'') COMMIT_COLS=70 ;; esac
[ "$SIDEBAR_COLS" -ge 20 ] 2>/dev/null || SIDEBAR_COLS=42
[ "$EXPAND_COLS" -ge 80 ] 2>/dev/null || EXPAND_COLS=80
[ "$COMMIT_COLS" -ge 40 ] 2>/dev/null || COMMIT_COLS=70

# AI pane 显示期间 lazygit 暂时按侧栏宽度摆放;关闭后恢复触发前模式。
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

# --- 单实例:关掉本 tab 里旧的 GitCommit pane ------------------------------
panes_json="$(herdr pane list 2>/dev/null || true)"
printf '%s' "$panes_json" | python3 -c '
import json, sys
tab = sys.argv[1]
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    panes = []
for p in panes:
    if p.get("tab_id") == tab and p.get("label") == "GitCommit":
        print(p["pane_id"])
' "$HERDR_TAB_ID" | while read -r old; do herdr pane close "$old" >/dev/null 2>&1 || true; done

# --- 打开 AI commit pane 并摆好几何 ---------------------------------------
new_pane="$(herdr pane split --pane "$HERDR_PANE_ID" --direction right --ratio 0.5 --focus 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
[ -n "$new_pane" ] || { echo "open-ai-commit-pane.sh: pane split failed" >&2; exit 1; }

herdr pane rename "$new_pane" "GitCommit" >/dev/null 2>&1 || true
python3 "$helper" place-diff "$HERDR_PANE_ID" "$new_pane" "$SIDEBAR_COLS" "$COMMIT_COLS" 2>/dev/null || true

restore_cmd="python3 $(shq "$helper") set-region-width $(shq "$HERDR_PANE_ID") $(shq "$restore_cols")"
run_cmd="clear; cd $(shq "$repo") && HERDR_PLUGIN_CONFIG_DIR=$(shq "$config_dir") bash $(shq "$commit_sh") $(shq "$repo"); $restore_cmd >/dev/null 2>&1; exit"
if ! herdr pane run "$new_pane" "$run_cmd" >/dev/null; then
  herdr pane close "$new_pane" >/dev/null 2>&1 || true
  python3 "$helper" set-region-width "$HERDR_PANE_ID" "$restore_cols" >/dev/null 2>&1 || true
  echo "open-ai-commit-pane.sh: pane run failed" >&2
  exit 1
fi
