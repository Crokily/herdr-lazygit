#!/usr/bin/env bash
# gen-config-layer.sh — 生成三层配置的中间层 generated.yml。
#
# 三层配置(见 DESIGN.md):
#   lazygit-config.yml(出厂,随插件)
#     → $HERDR_PLUGIN_CONFIG_DIR/generated.yml(本脚本生成,勿手改)
#       → $HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml(用户手写,永远最后=永远赢)
#
# 输入:$HERDR_PLUGIN_CONFIG_DIR/keys.conf(设置页写入,shell 可 source),
# 以及 panel.conf 的 LAYOUT_MODE(sidebar|expanded);缺失/缺项 = 用默认值:
#   KEY_COMMIT=C   KEY_ZOOM=U   KEY_SETTINGS=';'
# (U 与 ';' 来自 scripts/free-keys.py 对 lazygit 0.63.0 内置键的空闲键分析:
#  Z 被 universal.redo 占用,<c-s> 被 universal.filteringMenu 占用,
#  O 被 branches.viewPullRequestOptions 占用;U/';' 全面板零占用。)
#
# 输出:generated.yml,包含
#   - gui:按 LAYOUT_MODE 生成 sidebar/expanded 两种 lazygit 布局
#   - customCommands:KEY_COMMIT(打开 AI commit pane)、KEY_ZOOM(global,
#     切换布局)、KEY_SETTINGS(global,调 open-settings-pane.sh)
#   - keybinding:保留 KEY_SETTINGS 手写旧配置的按需 <disabled> 兼容逻辑。
#     KEY_ZOOM / KEY_SETTINGS 现在都是 global;设置页会用 free-keys.py check
#     拒绝任何面板冲突,默认 U / ';' 全面板空闲,正常不会生成本段。
#
# 幂等 + 毫秒级:generated.yml 比 keys.conf / 本脚本 / free-keys.py 都新时直接
# 跳过;写文件走 tmp+mv,避免 lazygit 热重载读到半截文件。
#
# bash 3.2 兼容(macOS 默认)。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
mkdir -p "$config_dir"
keys_conf="$config_dir/keys.conf"
panel_conf="$config_dir/panel.conf"
out="$config_dir/generated.yml"

# 插件三动词的默认键(设置页 settings-fzf.sh 的 DEF_KEY_* 必须与此保持一致)
def_commit='C' ; def_zoom='U' ; def_settings=';'

self="${BASH_SOURCE[0]:-$0}"

# --- 读 keys.conf(缺省用默认) ---------------------------------------------
# 在子 shell 里 source,坏文件(语法错误)不会打死本脚本,只会退回默认键。
k_commit="" ; k_zoom="" ; k_settings=""
if [ -f "$keys_conf" ]; then
  eval "$(
    ( . "$keys_conf" >/dev/null 2>&1 || exit 0
      printf 'k_commit=%q\nk_zoom=%q\nk_settings=%q\n' \
        "${KEY_COMMIT:-}" "${KEY_ZOOM:-}" "${KEY_SETTINGS:-}" ) 2>/dev/null
  )"
fi
[ -n "$k_commit" ]   || k_commit="$def_commit"
[ -n "$k_zoom" ]     || k_zoom="$def_zoom"
[ -n "$k_settings" ] || k_settings="$def_settings"

# --- 读 panel.conf 的布局状态(非法值退回 sidebar) -------------------------
layout_mode=""
if [ -f "$panel_conf" ]; then
  layout_mode="$(
    ( . "$panel_conf" >/dev/null 2>&1 || exit 0
      printf '%s' "${LAYOUT_MODE:-}" ) 2>/dev/null
  )"
fi
case "$layout_mode" in
  sidebar|expanded) ;;
  *) layout_mode="sidebar" ;;
esac

# --- 键位合法性校验:非法值退回默认并告警,绝不写进 generated.yml -----------
# lazygit 合法键 = 单字符,或 <...> 命名键(如 <c-s> <enter> <tab>)。
# 多字符裸串(如 abc)会让 lazygit 启动即报 "Unrecognized key" 拒绝加载
# (validation-error 屏,整个 lazygit pane 打不开),因此必须在生成前拦下,
# 退回默认键(见 DESIGN.md 的优雅降级约定:非法值 = 回退默认 + 告警)。
valid_key() {
  case "$1" in
    '<'*'>') [ ${#1} -ge 3 ] ;;   # 命名键 <...>
    *)       [ ${#1} -eq 1 ] ;;   # 恰好一个字符
  esac
}
warn_bad_key() {
  printf 'gen-config-layer.sh: 非法键位 %s=%s,已退回默认 %s(合法键:单字符或 <...> 命名键)\n' \
    "$1" "$2" "$3" >&2
}
valid_key "$k_commit"   || { warn_bad_key KEY_COMMIT   "$k_commit"   "$def_commit";   k_commit="$def_commit"; }
valid_key "$k_zoom"     || { warn_bad_key KEY_ZOOM     "$k_zoom"     "$def_zoom";     k_zoom="$def_zoom"; }
valid_key "$k_settings" || { warn_bad_key KEY_SETTINGS "$k_settings" "$def_settings"; k_settings="$def_settings"; }

# --- 缓存:generated.yml 已反映这套(校验后的)键就不重新生成 ----------------
# 用内容 marker 比对而非 mtime:bash 3.2 的 -nt 只比较整秒,同一秒内连续两次
# 改键(设置页快速连改)会因 mtime 相同而漏更新,且该陈旧状态跨重启持续
# (relaunch 时的 gen 也一并跳过)。直接比对头部 "# keys: ..." marker,与写入
# 时刻无关,彻底规避该问题;keys.conf 删除想恢复默认的场景也一并覆盖
# (此时 marker = 默认键行)。self / free-keys.py 变更仍用 -nt 兜底触发重生。
marker="# keys: $k_commit $k_zoom $k_settings | layout: $layout_mode"
if [ -f "$out" ] \
   && grep -qxF "$marker" "$out" 2>/dev/null \
   && [ ! "$self" -nt "$out" ] \
   && [ ! "$script_dir/free-keys.py" -nt "$out" ]; then
  exit 0
fi

# YAML 单引号转义('' 表示一个 ')
yaml_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

qc="$(yaml_quote "$k_commit")"
qz="$(yaml_quote "$k_zoom")"
qs="$(yaml_quote "$k_settings")"

case "$layout_mode" in
  expanded) side_panel_width="0.3333" ;;
  *)        side_panel_width="0.99" ;;
esac

# --- KEY_SETTINGS 的面板级冲突 → <disabled> ---------------------------------
# free-keys.py check 输出 "<ctx>\t<section>.<action>";universal 段不用管
# (global custom 本就压过 global 内置),只 disable 面板段的同键内置。
# free-keys.py 不可用(exit 2)时静默跳过——文件必须照常生成。
kb_section=""
if command -v python3 >/dev/null 2>&1; then
  conflicts="$(python3 "$script_dir/free-keys.py" check "$k_settings" global 2>/dev/null || true)"
  if [ -n "$conflicts" ]; then
    kb_section="$(printf '%s\n' "$conflicts" | awk -F'\t' '
      {
        n = split($2, a, ".")
        if (n != 2 || a[1] == "universal") next
        if (!(a[1] in seen)) { order[++cnt] = a[1]; seen[a[1]] = 1 }
        acts[a[1]] = acts[a[1]] "    " a[2] ": <disabled>\n"
      }
      END {
        if (cnt == 0) exit
        printf "\n# KEY_SETTINGS(%s)与以下面板内置键冲突,已按需禁用内置键\n", KEY
        printf "# (想还原:在设置页换一个空闲键)\n"
        printf "keybinding:\n"
        for (i = 1; i <= cnt; i++) printf "  %s:\n%s", order[i], acts[order[i]]
      }' KEY="$k_settings")"
  fi
fi

# --- 生成 --------------------------------------------------------------------
tmp="$out.tmp.$$"
{
  cat <<'EOF'
# generated.yml — machine-generated, do not edit(由 gen-config-layer.sh 生成)
EOF
  # marker 行:记录生成时用的键,供缓存判断"keys.conf 已删但本文件非默认键"
  printf '# keys: %s %s %s | layout: %s\n' \
    "$k_commit" "$k_zoom" "$k_settings" "$layout_mode"
  cat <<'EOF'
#
# 改键请走设置页(lazygit 里按设置键),或手改 keys.conf 后重开 lazygit。
# 想覆盖这里的任何配置,写 lazygit-user.yml(它在本文件之后加载,永远赢)。
EOF
  printf 'gui:\n  sidePanelWidth: %s\n' "$side_panel_width"
  cat <<'EOF'
  expandFocusedSidePanel: true
  portraitMode: never

customCommands:
EOF

  # -- KEY_COMMIT:打开即时反馈、可编辑的 AI commit pane(files 面板)---------
  printf '  - key: %s\n' "$qc"
  cat <<'EOF'
    context: 'files'
    description: '打开 AI commit pane'
    output: 'none'
    command: >-
      sh -c 'bash "$HERDR_LAZYGIT_ROOT/scripts/open-ai-commit-pane.sh"'
EOF

  # -- KEY_ZOOM:全局切换 sidebar / expanded 布局 ---------------------------
  printf '\n  - key: %s\n' "$qz"
  cat <<'EOF'
    context: 'global'
    description: '展开/收起 lazygit'
    output: 'none'
    command: >-
      sh -c 'bash "$HERDR_LAZYGIT_ROOT/scripts/toggle-expand.sh"'
EOF

  # -- KEY_SETTINGS:插件设置面板(global)------------------------------------
  printf '\n  - key: %s\n' "$qs"
  cat <<'EOF'
    context: 'global'
    description: '打开 herdr-lazygit 设置面板'
    command: >-
      sh -c 'bash "$HERDR_LAZYGIT_ROOT/scripts/open-settings-pane.sh"'
EOF

  [ -n "$kb_section" ] && printf '%s\n' "$kb_section"
} > "$tmp"
mv "$tmp" "$out"
