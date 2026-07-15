#!/usr/bin/env bash
# Show a diff in a dedicated herdr pane, using herdr (not lazygit) as the
# layout engine. Triggered by the `V` customCommand from inside the lazygit
# pane, so HERDR_PANE_ID / HERDR_TAB_ID identify the sidebar pane.
#
# Behavior:
#   - closes any previous "GitDiff" pane in this tab (only ever one at a time)
#   - splits the widest other pane in the tab (falls back to the sidebar pane,
#     splitting down) and runs the diff there through delta (or less)
#   - the pane runs "<diff> ; exit", so quitting the pager (q) closes the pane
#   - 无效的 hash / stash 索引不会空白闪退:引用校验在 pane 内执行,失败时
#     显示可读错误并停留数秒后自动关闭(侧栏宽度照常还原)
#
# Usage: show-diff-pane.sh file   <repo-relative-path>
#        show-diff-pane.sh commit <hash>
#        show-diff-pane.sh stash  <index>
#
# bash 3.2 compatible (macOS default).
set -euo pipefail

kind="${1:-file}"
target="${2:-}"
[ -n "$target" ] || exit 0
[ "${HERDR_ENV:-}" = "1" ] || { echo "show-diff-pane.sh: not inside herdr" >&2; exit 1; }

# 引号安全:bash 3.2 的 printf %q 会把多字节 UTF-8 拆成"原始字节+八进制
# 转义"的混合形式,herdr CLI(Rust)收到非法 UTF-8 argv 会直接 panic。
# 统一改用 python3 shlex.quote:单引号包裹、原始 UTF-8 原样保留。
shq() { python3 -c 'import shlex, sys; sys.stdout.write(shlex.quote(sys.argv[1]))' "$1"; }

repo="$(git rev-parse --show-toplevel)"
q_repo="$(shq "$repo")"
q_target="$(shq "$target")"

# --- build the command that renders the diff -------------------------------
# With delta: pipe raw git output into it. Without: let git colorize, page with less.
if command -v delta >/dev/null 2>&1; then
  git_cmd="git -C $q_repo"
  pager="delta --paging=always"
else
  git_cmd="git -c color.diff=always -C $q_repo"
  pager="less -R"
fi

# check_cmd 非空时会在 pane 内先跑校验:失败则显示 err_msg 并停留数秒,
# 避免 git 报错进 stderr、pager 秒退导致的"空白闪退"。
check_cmd=""
err_msg=""

case "$kind" in
  file)
    if git -C "$repo" ls-files --error-unmatch -- "$target" >/dev/null 2>&1; then
      # tracked: staged + unstaged combined
      base_cmd="$git_cmd diff HEAD -- $q_target"
    else
      # untracked: diff against /dev/null (exits 1 by design, so || true)
      base_cmd="{ $git_cmd diff --no-index -- /dev/null $q_repo/$q_target || true; }"
    fi
    ;;
  commit)
    # ^{commit} 顺带把 tag 剥成 commit;--quiet 抑制 stderr,失败走错误分支
    check_cmd="git -C $q_repo rev-parse --verify --quiet $(shq "${target}^{commit}") >/dev/null 2>&1"
    # -m --first-parent:合并提交默认 git show 不输出 diff(只有 header),
    # 放大查看会一片空白。--first-parent 显示"相对第一父的引入差异"(最符合
    # 直觉的"这次合并带进来了什么"),-m 强制对合并提交产出 diff;普通提交下
    # 二者与裸 git show 输出完全一致(已实测),故无副作用。
    base_cmd="$git_cmd show -m --first-parent $q_target"
    err_msg="无效的 commit: ${target}"
    ;;
  stash)
    # target 是 {{.SelectedStashEntry.Index}} 给的数字;非数字/越界都会被
    # rev-parse 拦下(stash@{abc} / stash@{99} 均解析失败)
    q_ref="$(shq "stash@{${target}}")"
    check_cmd="git -C $q_repo rev-parse --verify --quiet $q_ref >/dev/null 2>&1"
    # 标题行(stash@{N}: WIP on ...)+ 空行 + 补丁正文,一起交给 pager
    base_cmd="{ git -C $q_repo log -g -1 --format='%gd: %gs' $q_ref; echo; $git_cmd stash show -p $q_ref; }"
    err_msg="无效的 stash 索引: ${target}"
    ;;
  *)
    echo "show-diff-pane.sh: unknown kind '$kind'" >&2; exit 1 ;;
esac

view_cmd="$base_cmd | $pager"
if [ -n "$check_cmd" ]; then
  # 校验放在 pane 内执行(而非本脚本里),错误对用户可见;sleep 后自动关闭
  err_cmd="echo; echo $(shq "  herdr-lazygit: $err_msg"); echo $(shq '  (5 秒后自动关闭)'); sleep 5"
  view_cmd="if $check_cmd; then $view_cmd; else $err_cmd; fi"
fi

# --- geometry: the diff opens as a wide pane RIGHT of the sidebar ----------
# `pane split` can only divide the sidebar's own (narrow) rectangle, so after
# splitting we use layout-helper.py (layout.set_split_ratio over the herdr
# socket) to borrow width from the rest of the tab: the (git|diff) region
# grows to SIDEBAR_COLS+diff_cols, split SIDEBAR_COLS / diff_cols. Before the
# pager exits, the region shrinks back to SIDEBAR_COLS, so closing the diff
# leaves the sidebar at its configured width.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
helper="$script_dir/layout-helper.py"

SIDEBAR_COLS=42
DIFF_COLS=""   # empty -> 45% of the tab width
panel_conf="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}/panel.conf"
# shellcheck disable=SC1090
[ -f "$panel_conf" ] && . "$panel_conf"

# close the previous GitDiff pane in this tab (only ever one at a time)
panes_json="$(herdr pane list 2>/dev/null || true)"
printf '%s' "$panes_json" | python3 -c '
import json, sys
tab = sys.argv[1]
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    panes = []
for p in panes:
    if p.get("tab_id") == tab and p.get("label") == "GitDiff":
        print(p["pane_id"])
' "$HERDR_TAB_ID" | while read -r old; do herdr pane close "$old" >/dev/null 2>&1 || true; done

if [ -z "$DIFF_COLS" ]; then
  tab_w="$(herdr pane layout --pane "$HERDR_PANE_ID" 2>/dev/null | python3 -c '
import json, sys
print(json.load(sys.stdin)["result"]["layout"]["area"]["width"])' || echo 0)"
  DIFF_COLS=$(( tab_w * 45 / 100 ))
fi
[ "$DIFF_COLS" -ge 20 ] || DIFF_COLS=60

# --- open the pane and run the diff ----------------------------------------
new_pane="$(herdr pane split --pane "$HERDR_PANE_ID" --direction right --ratio 0.5 --focus 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
[ -n "$new_pane" ] || { echo "show-diff-pane.sh: pane split failed" >&2; exit 1; }

herdr pane rename "$new_pane" "GitDiff" >/dev/null 2>&1 || true
python3 "$helper" place-diff "$HERDR_PANE_ID" "$new_pane" "$SIDEBAR_COLS" "$DIFF_COLS" 2>/dev/null || true

# restore the sidebar width before exiting; "; exit" closes the pane on q
restore_cmd="python3 $(shq "$helper") set-region-width $(shq "$HERDR_PANE_ID") $(shq "$SIDEBAR_COLS")"
if ! herdr pane run "$new_pane" "clear; $view_cmd; $restore_cmd >/dev/null 2>&1; exit" >/dev/null; then
  # run 失败会留下一个空 shell pane:收掉并把侧栏还原,不给用户留残骸
  herdr pane close "$new_pane" >/dev/null 2>&1 || true
  python3 "$helper" set-region-width "$HERDR_PANE_ID" "$SIDEBAR_COLS" >/dev/null 2>&1 || true
  echo "show-diff-pane.sh: pane run failed" >&2
  exit 1
fi
