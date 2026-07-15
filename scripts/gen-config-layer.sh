#!/usr/bin/env bash
# gen-config-layer.sh — 生成三层配置的中间层 generated.yml。
#
# 三层配置(见 DESIGN.md):
#   lazygit-config.yml(出厂,随插件)
#     → $HERDR_PLUGIN_CONFIG_DIR/generated.yml(本脚本生成,勿手改)
#       → $HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml(用户手写,永远最后=永远赢)
#
# 输入:$HERDR_PLUGIN_CONFIG_DIR/keys.conf(设置页写入,shell 可 source),
# 仅承载插件三个动词的键位;缺失/缺项 = 用默认值:
#   KEY_COMMIT=C   KEY_ZOOM=U   KEY_SETTINGS=';'
# (U 与 ';' 来自 scripts/free-keys.py 对 lazygit 0.63.0 内置键的空闲键分析:
#  Z 被 universal.redo 占用,<c-s> 被 universal.filteringMenu 占用,
#  O 被 branches.viewPullRequestOptions 占用;U/';' 全面板零占用。)
#
# 输出:generated.yml,包含
#   - customCommands:KEY_COMMIT(AI commit 全流程)、KEY_ZOOM ×3(files /
#     commits+subCommits+reflogCommits / stash,调 show-diff-pane.sh)、
#     KEY_SETTINGS(global,调 open-settings-pane.sh)
#   - keybinding:仅当 KEY_SETTINGS 与某"面板级"内置键冲突时按需 <disabled>
#     (global 自定义命令会被面板内置键遮蔽——S 在 files 弹 stash 菜单实测踩雷;
#      KEY_ZOOM 是面板级自定义命令,天然压过同面板/universal 内置键,无需 disable;
#      正常情况下设置页已用 free-keys.py check 拒绝冲突键,此段应为空)
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
out="$config_dir/generated.yml"

# --- 缓存:输入都没变就不重新生成 -------------------------------------------
self="${BASH_SOURCE[0]:-$0}"
if [ -f "$out" ] && [ ! "$self" -nt "$out" ] && [ ! "$script_dir/free-keys.py" -nt "$out" ]; then
  if [ ! -f "$keys_conf" ] || [ ! "$keys_conf" -nt "$out" ]; then
    exit 0
  fi
fi

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
[ -n "$k_commit" ]   || k_commit='C'
[ -n "$k_zoom" ]     || k_zoom='U'
[ -n "$k_settings" ] || k_settings=';'

# YAML 单引号转义('' 表示一个 ')
yaml_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

qc="$(yaml_quote "$k_commit")"
qz="$(yaml_quote "$k_zoom")"
qs="$(yaml_quote "$k_settings")"

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
#
# 改键请走设置页(lazygit 里按设置键),或手改 keys.conf 后重开 lazygit。
# 想覆盖这里的任何配置,写 lazygit-user.yml(它在本文件之后加载,永远赢)。
customCommands:
EOF

  # -- KEY_COMMIT:AI 生成 commit message(files 面板)------------------------
  printf '  - key: %s\n' "$qc"
  cat <<'EOF'
    context: 'files'
    description: 'AI 生成 commit message'
    loadingText: '正在提交…'
    output: 'log'
    # lazygit 不会把命令交给 shell 展开,所以显式用 sh -c 包一层,让
    # $HERDR_LAZYGIT_ROOT 得以展开;选中值通过位置参数 $1 传入,避免转义问题。
    # 脚本的错误提示行以 "(" 开头(如 "(没有 staged 改动 …)"),
    # 选中这类行时不会真正 commit,只把提示回显到 command log。
    prompts:
      - type: 'menuFromCommand'
        title: 'AI commit message 候选(生成中,可能需要几秒…)'
        key: 'Msg'
        command: "sh -c 'bash \"$HERDR_LAZYGIT_ROOT/scripts/ai-commit-msg.sh\" candidates'"
    command: >-
      sh -c 'case "$1" in "("*) printf "%s\n" "$1" ;; *) git commit -m "$1" ;; esac' sh {{.Form.Msg | quote}}
EOF

  # -- KEY_ZOOM ×3:在 herdr pane 中放大查看 ----------------------------------
  printf '\n  - key: %s\n' "$qz"
  cat <<'EOF'
    context: 'files'
    description: '在 herdr pane 中放大查看 diff'
    command: >-
      sh -c 'bash "$HERDR_LAZYGIT_ROOT/scripts/show-diff-pane.sh" file "$1"' sh {{.SelectedPath | quote}}
EOF
  printf '\n  - key: %s\n' "$qz"
  cat <<'EOF'
    context: 'commits, subCommits, reflogCommits'
    description: '在 herdr pane 中放大查看 commit'
    command: >-
      sh -c 'bash "$HERDR_LAZYGIT_ROOT/scripts/show-diff-pane.sh" commit "$1"' sh {{.SelectedCommit.Hash | quote}}
EOF
  printf '\n  - key: %s\n' "$qz"
  cat <<'EOF'
    context: 'stash'
    description: '在 herdr pane 中放大查看 stash'
    command: >-
      sh -c 'bash "$HERDR_LAZYGIT_ROOT/scripts/show-diff-pane.sh" stash "$1"' sh {{.SelectedStashEntry.Index | quote}}
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
