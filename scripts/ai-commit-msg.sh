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

# 每个后端用的模型:commit message 是小活,默认刻意用便宜/快的档,
# 避免继承用户 CLI 的默认模型(可能是最贵档 + 高推理强度)。
# 在 ai-backend.conf 里覆盖;设为空字符串则回退到该 CLI 自己的默认。
AI_CLAUDE_MODEL="${AI_CLAUDE_MODEL-haiku}"
AI_CODEX_MODEL="${AI_CODEX_MODEL-}"   # 空 = codex 自己的默认(无公认稳定的便宜档 id,不猜)
AI_OPENCODE_MODEL="${AI_OPENCODE_MODEL-google/gemini-2.5-flash}"

CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
CONFIG_FILE="$CONFIG_DIR/ai-backend.conf"

MSG_NO_STAGED="(没有 staged 改动 — 先用空格 stage 文件)"
MSG_NO_BACKEND="(未找到可用的 AI CLI:claude/codex/opencode/gemini)"
MSG_NO_CUSTOM_CMD="(custom 后端未配置 AI_CUSTOM_CMD — 编辑 ai-backend.conf 或按 B 换后端)"
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
  # 用户自定义 prompt(E 键编辑):存在且非空则覆盖内置 PROMPT
  if [ -s "$CONFIG_DIR/prompt.txt" ]; then
    PROMPT="$(cat "$CONFIG_DIR/prompt.txt")"
  fi
}

# 更新 conf 里的单个 KEY=VALUE,保留其他行(set-backend 早期实现会整写
# conf 丢掉别的键,这里统一走这个助手)。值以单引号安全转义写入。
write_conf_var() {
  local key="$1" value="$2" tmp
  mkdir -p "$CONFIG_DIR"
  tmp="$(mktemp "${TMPDIR:-/tmp}/ai-backend.conf.XXXXXX")"
  if [ -f "$CONFIG_FILE" ]; then
    grep -v "^${key}=" "$CONFIG_FILE" > "$tmp" || true
  fi
  printf "%s='%s'\n" "$key" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# 带超时地运行命令:stdin 透传,stdout 透传;stderr 默认丢弃,
# 若设置了 AI_ERR_FILE 则写入该文件(供失败时提取诊断提示)。
# 超时 exit 124;其余透传子进程退出码。
run_with_timeout() {
  python3 -c '
import os, subprocess, sys
timeout = float(sys.argv[1])
err_path = os.environ.get("AI_ERR_FILE") or ""
err = open(err_path, "wb") if err_path else subprocess.DEVNULL
try:
    p = subprocess.run(sys.argv[2:], stdin=sys.stdin.buffer,
                       stdout=subprocess.PIPE, stderr=err,
                       timeout=timeout)
except subprocess.TimeoutExpired:
    sys.exit(124)
except FileNotFoundError:
    sys.exit(127)
finally:
    if err is not subprocess.DEVNULL:
        err.close()
sys.stdout.buffer.write(p.stdout)
sys.exit(p.returncode)
' "$TIMEOUT_SEC" "$@"
}

# 从 stderr 文件里提取一行简短诊断(去 ANSI,优先含 Error/error 的行,截断)
stderr_hint() {
  # $1 = stderr 文件路径
  [ -s "${1:-}" ] || return 0
  python3 -c '
import re, sys
try:
    data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
except OSError:
    sys.exit(0)
data = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", data)   # 去 ANSI 转义
lines = [l.strip() for l in data.splitlines() if l.strip()]
if not lines:
    sys.exit(0)
pick = next((l for l in lines if re.search(r"error", l, re.I)), lines[-1])
if len(pick) > 80:
    pick = pick[:77] + "..."
sys.stdout.write(pick)
' "$1"
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
  # 注意:不能加 --bare(此版本会导致 keychain 凭据读取失败报 Not logged in)。
  # 显式 --model(默认 haiku),避免继承用户 CLI 的贵档默认模型。
  if [ -n "$AI_CLAUDE_MODEL" ]; then
    run_with_timeout claude -p --model "$AI_CLAUDE_MODEL" "$PROMPT"
  else
    run_with_timeout claude -p "$PROMPT"
  fi
}

gen_opencode() {
  # 默认模型不可用,必须显式 -m;stderr(横幅/ANSI)已被 run_with_timeout 丢弃
  run_with_timeout opencode run -m "${AI_OPENCODE_MODEL:-google/gemini-2.5-flash}" "$PROMPT"
}

gen_codex() {
  # 最终 message 从 -o 文件读最可靠(stdout 不保证长期只有 message)
  local outfile rc model_args
  model_args=""
  [ -n "$AI_CODEX_MODEL" ] && model_args="-m $AI_CODEX_MODEL"
  outfile="$(mktemp "${TMPDIR:-/tmp}/ai-commit-msg.codex.XXXXXX")"
  rc=0
  # shellcheck disable=SC2086
  run_with_timeout codex exec --skip-git-repo-check -s read-only --color never \
    $model_args -o "$outfile" "$PROMPT" >/dev/null || rc=$?
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
    # 按配置区分原因,避免一律回答「未找到 AI CLI」误导用户
    case "$AI_BACKEND" in
      custom) printf '%s\n' "$MSG_NO_CUSTOM_CMD" ;;
      auto)   printf '%s\n' "$MSG_NO_BACKEND" ;;
      *)      printf '(当前后端 %s 未安装 — 按 B 换后端)\n' "$AI_BACKEND" ;;
    esac
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

  local err_file hint
  err_file="$(mktemp "${TMPDIR:-/tmp}/ai-commit-msg.err.XXXXXX")"

  rc=0
  raw="$(printf '%s' "$diff" | AI_ERR_FILE="$err_file" "gen_$backend")" || rc=$?

  if [ "$rc" -eq 124 ]; then
    rm -f "$err_file"
    printf '%s\n' "$MSG_TIMEOUT"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    # 失败时带上后端名和一行 stderr 摘要(如 gemini 的 IneligibleTierError),
    # 否则用户只看到笼统的失败提示,无从排查登录/资格问题
    hint="$(stderr_hint "$err_file" || true)"
    rm -f "$err_file"
    if [ -n "$hint" ]; then
      printf '(AI 生成失败[%s]: %s — 请检查后端登录状态或换后端)\n' "$backend" "$hint"
    else
      printf '%s\n' "$MSG_FAILED"
    fi
    return 0
  fi
  rm -f "$err_file"

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
  # custom 后端必须先配置 AI_CUSTOM_CMD,否则 candidates 会一路失败,
  # 且错误提示会误导用户以为是没装 AI CLI
  if [ "$name" = "custom" ] && [ -z "$AI_CUSTOM_CMD" ]; then
    echo "无法切换到 custom 后端:AI_CUSTOM_CMD 未配置。" >&2
    echo "请先在 $CONFIG_FILE 中加入一行,例如:" >&2
    echo "  AI_CUSTOM_CMD='my-ai-cli --flag'   # stdin 收 prompt+diff,stdout 出 message" >&2
    echo "再执行 set-backend custom。" >&2
    return 1
  fi
  write_conf_var AI_BACKEND "$name"
  echo "AI 后端已设置为: $name"
}

# 当前(auto 时解析后的)后端名;custom/无可用后端时输出空
current_model_backend() {
  load_config
  local b="$AI_BACKEND"
  if [ "$b" = "auto" ]; then
    b=""
    for cand in $BACKEND_ORDER; do
      if has_cmd "$cand"; then b="$cand"; break; fi
    done
  fi
  case "$b" in claude|codex|opencode|gemini) printf '%s' "$b" ;; *) printf '' ;; esac
}

model_var_for() {
  case "$1" in
    claude)   echo AI_CLAUDE_MODEL ;;
    codex)    echo AI_CODEX_MODEL ;;
    opencode) echo AI_OPENCODE_MODEL ;;
    gemini)   echo AI_GEMINI_MODEL ;;
  esac
}

# models — 输出当前后端的候选模型,一行一个(菜单数据源)。
# 第一行是当前值;能动态取列表的后端(opencode)动态取,其余给常用档。
cmd_models() {
  local backend cur
  backend="$(current_model_backend)"
  if [ -z "$backend" ]; then
    echo "(当前后端不支持选模型 — custom 后端请直接改 AI_CUSTOM_CMD)"
    return 0
  fi
  cur="$(eval "printf '%s' \"\${$(model_var_for "$backend")-}\"")"
  [ -n "$cur" ] && printf '%s\n' "$cur"
  case "$backend" in
    claude)
      printf '%s\n' haiku sonnet opus ;;
    opencode)
      opencode models 2>/dev/null || true ;;
    codex|gemini)
      # 无公开的列表命令;给一个占位项,用户在下一步输入框里改成真实 id
      echo "(在下一步输入框填模型 id;清空 = 跟随 CLI 默认)" ;;
  esac | grep -v "^${cur}\$" || true
}

# set-model VALUE — 为当前后端写入模型(空值 = 跟随该 CLI 自己的默认)
cmd_set_model() {
  local value="${1:-}" backend
  backend="$(current_model_backend)"
  if [ -z "$backend" ]; then
    echo "当前后端不支持设置模型" >&2
    return 1
  fi
  case "$value" in "("*) echo "已取消" ; return 0 ;; esac
  write_conf_var "$(model_var_for "$backend")" "$value"
  echo "$backend 的模型已设置为: ${value:-（CLI 默认）}"
}

# prompt-file — 确保用户 prompt 文件存在(首次用内置 PROMPT 播种),输出路径
cmd_prompt_file() {
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_DIR/prompt.txt" ]; then
    printf '%s\n' "$PROMPT" > "$CONFIG_DIR/prompt.txt"
  fi
  printf '%s\n' "$CONFIG_DIR/prompt.txt"
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
    models)      cmd_models ;;
    set-model)   shift; cmd_set_model "$@" ;;
    prompt-file) cmd_prompt_file ;;
    *)
      echo "用法: ai-commit-msg.sh candidates|backends|set-backend NAME|models|set-model VALUE|prompt-file" >&2
      return 1
      ;;
  esac
}

main "$@"
