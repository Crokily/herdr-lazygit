#!/usr/bin/env bash
# ai-commit-pane.sh — GitCommit pane 内的即时反馈、可编辑 AI commit UI。
#
# 打开后先显示后端/模型与 spinner,后台运行 ai-commit-msg.sh candidates;
# 成功后用 fzf 选择、编辑或自写 message,最后直接在传入仓库中提交。
# Ctrl-C 在生成阶段会终止 AI 子进程并退出。
#
# bash 3.2 兼容(macOS 默认)。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
AI_SH="$script_dir/ai-commit-msg.sh"
repo="${1:-$(pwd)}"
config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
ai_conf="$config_dir/ai-backend.conf"

if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  printf 'herdr-lazygit:不是 git 仓库:%s\n\n按任意键关闭...' "$repo" >&2
  IFS= read -rsn1 _ || true
  exit 1
fi
cd "$repo"

# 只读本地配置来生成即时状态行;不调用可能联网或较慢的模型列表命令。
AI_BACKEND_ENV="${AI_BACKEND:-}"
AI_BACKEND=auto
AI_CUSTOM_CMD=""
AI_CLAUDE_MODEL=haiku
AI_CODEX_MODEL=""
AI_OPENCODE_MODEL=google/gemini-2.5-flash
AI_GEMINI_MODEL=""
# shellcheck disable=SC1090
{ [ -f "$ai_conf" ] && . "$ai_conf"; } || true
[ -n "$AI_BACKEND_ENV" ] && AI_BACKEND="$AI_BACKEND_ENV"

resolved="$AI_BACKEND"
if [ "$resolved" = "auto" ]; then
  resolved=""
  for candidate in claude codex opencode gemini; do
    if command -v "$candidate" >/dev/null 2>&1; then
      resolved="$candidate"
      break
    fi
  done
fi

case "$resolved" in
  claude)   model="$AI_CLAUDE_MODEL" ;;
  codex)    model="$AI_CODEX_MODEL" ;;
  opencode) model="$AI_OPENCODE_MODEL" ;;
  gemini)   model="$AI_GEMINI_MODEL" ;;
  custom)   model="自定义命令" ;;
  *)        model="" ;;
esac
[ -n "$model" ] || model="CLI 默认"
if [ "$AI_BACKEND" = "auto" ]; then
  backend_text="auto → ${resolved:-未找到可用后端}"
else
  backend_text="$AI_BACKEND"
fi

clear
printf 'herdr-lazygit · AI Commit\n后端:%s  ·  模型:%s\n\n' "$backend_text" "$model"

if ! command -v fzf >/dev/null 2>&1; then
  cat >&2 <<'EOF'
缺少 fzf(AI commit 候选与 message 编辑界面)。

安装方式:
  brew install fzf

按任意键关闭...
EOF
  IFS= read -rsn1 _ || true
  exit 1
fi

candidates_file="$(mktemp "${TMPDIR:-/tmp}/herdr-lazygit.candidates.XXXXXX")"
error_file="$(mktemp "${TMPDIR:-/tmp}/herdr-lazygit.ai-error.XXXXXX")"
commit_out="$(mktemp "${TMPDIR:-/tmp}/herdr-lazygit.commit-out.XXXXXX")"
commit_err="$(mktemp "${TMPDIR:-/tmp}/herdr-lazygit.commit-err.XXXXXX")"
preview_file="$(mktemp "${TMPDIR:-/tmp}/herdr-lazygit.preview.XXXXXX")"
ai_pid=""

cleanup() {
  if [ -n "$ai_pid" ]; then
    kill "$ai_pid" >/dev/null 2>&1 || true
    wait "$ai_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$candidates_file" "$error_file" "$commit_out" "$commit_err" "$preview_file"
}
cancel_generation() {
  printf '\r\033[2K已取消 AI 生成。\n'
  if [ -n "$ai_pid" ]; then
    kill "$ai_pid" >/dev/null 2>&1 || true
    wait "$ai_pid" >/dev/null 2>&1 || true
    ai_pid=""
  fi
  exit 0
}
trap cleanup EXIT
trap cancel_generation INT TERM

# 预渲染"即将提交"预览(静态内容,只渲染一次,fzf preview 里 cat 即可):
# 一行 shortstat 当标题,下面是 delta 渲染的完整 staged diff(滚轮可滚)。
# 树状文件列表左边 lazygit 已有,这里只放侧栏单栏模式下看不到的东西。
cols="$(tput cols 2>/dev/null || echo 80)"
shortstat="$(git -C "$repo" diff --cached --shortstat | sed 's/^ *//')"
{
  printf '\033[1m%s\033[0m\n\n' "${shortstat:-无 staged 改动}"
  if command -v delta >/dev/null 2>&1; then
    git -C "$repo" diff --cached | delta --paging=never --width "$((cols > 4 ? cols - 2 : cols))" || true
  else
    git -C "$repo" -c color.diff=always diff --cached || true
  fi
} > "$preview_file" 2>/dev/null || true

# 等待期先把提交规模亮出来,这几秒可以开始想 message 了
printf '即将提交:%s\n\n' "${shortstat:-?}"
printf '⏳ AI 生成中…(Ctrl-C 取消)'
HERDR_PLUGIN_CONFIG_DIR="$config_dir" bash "$AI_SH" candidates \
  >"$candidates_file" 2>"$error_file" &
ai_pid=$!

frames='|/-\'
tick=0
while kill -0 "$ai_pid" >/dev/null 2>&1; do
  frame="${frames:$((tick % 4)):1}"
  printf '\r%s AI 生成中…(Ctrl-C 取消)' "$frame"
  tick=$((tick + 1))
  sleep 0.1
done

gen_rc=0
wait "$ai_pid" || gen_rc=$?
ai_pid=""
trap - INT TERM
printf '\r\033[2K'

if [ "$gen_rc" -ne 0 ] && [ ! -s "$candidates_file" ]; then
  hint="$(tail -1 "$error_file" 2>/dev/null || true)"
  printf '(AI 生成失败%s)\n' "${hint:+: $hint}" > "$candidates_file"
fi

first_line="$(sed -n '1p' "$candidates_file")"
case "$first_line" in
  '('*)
    printf '%s\n\n按任意键关闭...' "$first_line"
    IFS= read -rsn1 _ || true
    exit 0
    ;;
esac

if [ -z "$first_line" ]; then
  printf '(AI 没有返回可用候选)\n\n按任意键关闭...'
  IFS= read -rsn1 _ || true
  exit 0
fi

# preview:上半是选中候选的完整 message(永不截断),下半 cat 预渲染的
# staged diff。{} 由 fzf 以安全引号替换;列表过滤到空时显示自写提示。
q_preview_file="$(python3 -c 'import shlex,sys; sys.stdout.write(shlex.quote(sys.argv[1]))' "$preview_file")"
preview_cmd='msg={}; if [ -n "$msg" ]; then printf "\033[1m✏ %s\033[0m\n\n" "$msg"; else printf "\033[1m✏ (输入框内容将作为 message)\033[0m\n\n"; fi; cat '"$q_preview_file"

fzf_out=""
fzf_rc=0
fzf_out="$(fzf --layout=reverse --no-multi --print-query \
  --prompt='Commit message > ' \
  --header='回车=提交 · 直接打字=编辑/自写 · Esc=取消' \
  --wrap --gap 1 --gap-line --highlight-line \
  --preview "$preview_cmd" \
  --preview-window 'down,65%,wrap' \
  --preview-label '─ 即将提交 ' \
  --bind 'double-click:accept' < "$candidates_file")" || fzf_rc=$?

# Esc/中断返回 >=2;无匹配但保留 query 时 fzf 可返回 1,仍按 query 提交。
if [ "$fzf_rc" -ge 2 ]; then
  exit 0
fi
query="$(printf '%s\n' "$fzf_out" | sed -n '1p')"
selected="$(printf '%s\n' "$fzf_out" | sed -n '2p')"
message="${selected:-$query}"
message="$(printf '%s' "$message" | python3 -c 'import sys; sys.stdout.write(sys.stdin.read().strip())')"
[ -n "$message" ] || exit 0

clear
printf '正在提交:%s\n\n' "$message"
if git -C "$repo" commit -m "$message" >"$commit_out" 2>"$commit_err"; then
  short_hash="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)"
  printf '✓ 已提交 %s\n%s\n' "$short_hash" "$message"
else
  printf '✗ git commit 失败:\n'
  if [ -s "$commit_err" ]; then
    cat "$commit_err"
  else
    cat "$commit_out"
  fi
fi
sleep 2
