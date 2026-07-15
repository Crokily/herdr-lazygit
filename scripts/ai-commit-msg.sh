#!/usr/bin/env bash
# ai-commit-msg.sh — AI 生成 conventional commit message(herdr-lazygit 插件)
#
# 子命令:
#   candidates        读 staged diff,输出最多 3 个 commit message 候选(每行一个)
#   backends          每行输出 "名字<TAB>状态"(detected/missing/current)
#   set-backend NAME  写入配置文件(auto|claude|codex|opencode|gemini|custom)
#
# 配置文件:$HERDR_PLUGIN_CONFIG_DIR/ai-backend.conf(shell 可 source 格式)
#   AI_BACKEND=auto|claude|codex|opencode|gemini|custom
#   AI_CUSTOM_CMD="..."   # custom 时:stdin 收 prompt+diff,stdout 出 message
#
# bash 3.2 兼容(macOS 默认)。JSON/文本处理用 python3,不用 jq。

set -euo pipefail

# ---------------------------------------------------------------------------
# 常量与配置
# ---------------------------------------------------------------------------

TIMEOUT_SEC="${AI_TIMEOUT_SEC:-60}"
DIFF_MAX_CHARS=8000
BACKEND_ORDER="claude codex opencode gemini"   # auto 探测顺序

CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
CONFIG_FILE="$CONFIG_DIR/ai-backend.conf"

MSG_NO_STAGED="(没有 staged 改动 — 先用空格 stage 文件)"
MSG_NO_BACKEND="(未找到可用的 AI CLI:claude/codex/opencode/gemini)"
MSG_TIMEOUT="(AI 生成超时,请重试或换后端)"
MSG_FAILED="(AI 生成失败,请检查后端登录状态或换后端)"

PROMPT='Generate up to 3 alternative conventional commit messages (feat/fix/docs/refactor/chore/test/perf/build/ci/style) for the following git diff. Output ONLY the commit messages, one per line, at most 3 lines. Each message must be a single line in English with a subject of at most 72 characters. No numbering, no bullets, no markdown, no quotes, no explanations.'

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

# 环境变量里的 AI_BACKEND 优先于配置文件(便于临时切换/测试)
AI_BACKEND_ENV="${AI_BACKEND:-}"

load_config() {
  AI_BACKEND="auto"
  AI_CUSTOM_CMD=""
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE" || true
  fi
  if [ -n "$AI_BACKEND_ENV" ]; then
    AI_BACKEND="$AI_BACKEND_ENV"
  fi
  AI_BACKEND="${AI_BACKEND:-auto}"
  AI_CUSTOM_CMD="${AI_CUSTOM_CMD:-}"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# 带超时地运行命令:stdin 透传,stdout 透传,stderr 丢弃。
# 超时 exit 124;其余透传子进程退出码。
run_with_timeout() {
  python3 -c '
import subprocess, sys
timeout = float(sys.argv[1])
try:
    p = subprocess.run(sys.argv[2:], stdin=sys.stdin.buffer,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       timeout=timeout)
except subprocess.TimeoutExpired:
    sys.exit(124)
except FileNotFoundError:
    sys.exit(127)
sys.stdout.buffer.write(p.stdout)
sys.exit(p.returncode)
' "$TIMEOUT_SEC" "$@"
}

# 净化模型输出:去 markdown 围栏/前后引号/空行/"commit message:" 前缀/编号,最多留 3 行
sanitize_output() {
  python3 -c '
import re, sys
out = []
for line in sys.stdin.read().splitlines():
    s = line.strip()
    if not s or s.startswith("```") or s.startswith("~~~"):
        continue
    s = s.strip("`\"\x27 \t")       # 先去反引号/双引号/单引号(\x27 = 单引号)
    s = re.sub(r"(?i)^(commit\s+messages?|messages?|candidates?)\s*[::]\s*", "", s)
    s = re.sub(r"^\d+\s*[.)::]\s*", "", s)   # 1. / 2) 编号
    s = re.sub(r"^[-*+]\s+", "", s)          # 列表符号
    s = s.strip("`\"\x27 \t").strip()
    if not s:
        continue
    out.append(s)
    if len(out) == 3:
        break
sys.stdout.write("\n".join(out))
'
}

# ---------------------------------------------------------------------------
# 各后端调用(diff 走 stdin,prompt 走 argv;实测结论见 Spike)
# ---------------------------------------------------------------------------

gen_claude() {
  # 注意:不能加 --bare(此版本会导致 keychain 凭据读取失败报 Not logged in)
  run_with_timeout claude -p "$PROMPT"
}

gen_opencode() {
  # 默认模型不可用,必须显式 -m;stderr(横幅/ANSI)已被 run_with_timeout 丢弃
  run_with_timeout opencode run -m google/gemini-2.5-flash "$PROMPT"
}

gen_codex() {
  # 最终 message 从 -o 文件读最可靠(stdout 不保证长期只有 message)
  local outfile rc
  outfile="$(mktemp "${TMPDIR:-/tmp}/ai-commit-msg.codex.XXXXXX")"
  rc=0
  run_with_timeout codex exec --skip-git-repo-check -s read-only --color never \
    -o "$outfile" "$PROMPT" >/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    cat "$outfile"
  fi
  rm -f "$outfile"
  return "$rc"
}

gen_gemini() {
  run_with_timeout gemini -p "$PROMPT"
}

gen_custom() {
  # 契约:stdin 收 prompt+diff,stdout 出 message
  local diff_text
  diff_text="$(cat)"
  printf '%s\n\n%s' "$PROMPT" "$diff_text" | run_with_timeout sh -c "$AI_CUSTOM_CMD"
}

# ---------------------------------------------------------------------------
# 后端解析
# ---------------------------------------------------------------------------

# 输出解析出的后端名;解析失败输出空
resolve_backend() {
  local b
  case "$AI_BACKEND" in
    auto)
      for b in $BACKEND_ORDER; do
        if has_cmd "$b"; then
          printf '%s' "$b"
          return 0
        fi
      done
      ;;
    claude|codex|opencode|gemini)
      if has_cmd "$AI_BACKEND"; then
        printf '%s' "$AI_BACKEND"
        return 0
      fi
      ;;
    custom)
      if [ -n "$AI_CUSTOM_CMD" ]; then
        printf 'custom'
        return 0
      fi
      ;;
  esac
  printf ''
}

# ---------------------------------------------------------------------------
# 子命令:candidates
# ---------------------------------------------------------------------------

cmd_candidates() {
  load_config

  local diff backend raw rc result
  diff="$(git diff --cached 2>/dev/null || true)"
  if [ -z "$diff" ]; then
    printf '%s\n' "$MSG_NO_STAGED"
    return 0
  fi

  backend="$(resolve_backend)"
  if [ -z "$backend" ]; then
    printf '%s\n' "$MSG_NO_BACKEND"
    return 0
  fi

  # diff 截断
  diff="$(printf '%s' "$diff" | python3 -c '
import sys
limit = int(sys.argv[1])
d = sys.stdin.read()
if len(d) > limit:
    d = d[:limit] + "\n\n[diff truncated at " + str(limit) + " chars]"
sys.stdout.write(d)
' "$DIFF_MAX_CHARS")"

  rc=0
  raw="$(printf '%s' "$diff" | "gen_$backend")" || rc=$?

  if [ "$rc" -eq 124 ]; then
    printf '%s\n' "$MSG_TIMEOUT"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$MSG_FAILED"
    return 0
  fi

  result="$(printf '%s' "$raw" | sanitize_output)"
  if [ -z "$result" ]; then
    printf '%s\n' "$MSG_FAILED"
    return 0
  fi
  printf '%s\n' "$result"
}

# ---------------------------------------------------------------------------
# 子命令:backends
# ---------------------------------------------------------------------------

cmd_backends() {
  load_config
  local b status
  # auto 一行,便于在菜单里切回自动探测
  if [ "$AI_BACKEND" = "auto" ]; then
    printf 'auto\tcurrent\n'
  else
    printf 'auto\tdetected\n'
  fi
  for b in $BACKEND_ORDER; do
    if [ "$AI_BACKEND" = "$b" ]; then
      status="current"
    elif has_cmd "$b"; then
      status="detected"
    else
      status="missing"
    fi
    printf '%s\t%s\n' "$b" "$status"
  done
  if [ -n "$AI_CUSTOM_CMD" ] || [ "$AI_BACKEND" = "custom" ]; then
    if [ "$AI_BACKEND" = "custom" ]; then
      printf 'custom\tcurrent\n'
    elif [ -n "$AI_CUSTOM_CMD" ]; then
      printf 'custom\tdetected\n'
    fi
  fi
}

# ---------------------------------------------------------------------------
# 子命令:set-backend NAME
# ---------------------------------------------------------------------------

cmd_set_backend() {
  local name="${1:-}"
  case "$name" in
    auto|claude|codex|opencode|gemini|custom) ;;
    *)
      echo "用法: ai-commit-msg.sh set-backend auto|claude|codex|opencode|gemini|custom" >&2
      return 1
      ;;
  esac

  load_config
  mkdir -p "$CONFIG_DIR"
  {
    printf 'AI_BACKEND=%s\n' "$name"
    if [ -n "$AI_CUSTOM_CMD" ]; then
      # 保留已有的 custom 命令(single-quote 安全转义)
      printf "AI_CUSTOM_CMD='%s'\n" "$(printf '%s' "$AI_CUSTOM_CMD" | sed "s/'/'\\\\''/g")"
    fi
  } > "$CONFIG_FILE"
  echo "AI 后端已设置为: $name"
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

main() {
  local sub="${1:-}"
  case "$sub" in
    candidates)  cmd_candidates ;;
    backends)    cmd_backends ;;
    set-backend) shift; cmd_set_backend "$@" ;;
    *)
      echo "用法: ai-commit-msg.sh candidates|backends|set-backend NAME" >&2
      return 1
      ;;
  esac
}

main "$@"
