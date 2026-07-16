#!/usr/bin/env bash
# settings-fzf.sh — herdr-lazygit 插件设置页(fzf 循环菜单)。
#
# 一般由 open-settings-pane.sh 在专属 herdr pane 里启动(它负责摆几何),
# 也可以直接在任意终端手动运行。
#
# 交互模型:
#   主菜单 = fzf 列表(preview 窗显示每项的当前值+说明);
#   Enter / 鼠标双击 = 进入子流程修改;Esc / q = 退出设置页。
#   子流程里 Esc(或 fzf 取消)= 放弃修改返回主菜单。
#
# 子流程一览:
#   AI 后端      → fzf 列表(数据:ai-commit-msg.sh backends)
#   AI 模型      → fzf 列表(数据:ai-commit-msg.sh models)+ --print-query 手动输入
#   AI Prompt    → $EDITOR 打开 prompt.txt(ai-commit-msg.sh prompt-file)
#   键位:*      → 按下新键(read -rsn1),free-keys.py check 校验冲突,
#                  冲突则显示占用方并拒绝(free-keys.py 未就绪时跳过校验)
#   宽度         → read 数字校验,写 panel.conf(留空 = 恢复默认)
#
# 每次改动:立刻写入对应 conf,并调用 gen-config-layer.sh 重新生成
# generated.yml(脚本未就绪时容错跳过)。lazygit 0.63+ 在终端重新获得焦点时
# 会热重载全部配置文件,所以切回 lazygit pane 改动即生效——无需重启。
#
# 配置文件(都在 $HERDR_PLUGIN_CONFIG_DIR,shell 可 source):
#   ai-backend.conf  AI_BACKEND / AI_<BACKEND>_MODEL / AI_CUSTOM_CMD
#   keys.conf        KEY_COMMIT / KEY_ZOOM / KEY_SETTINGS(缺失 = 插件默认;
#                    只存插件三动词的键,内置键重映射请编辑 lazygit-user.yml)
#   panel.conf       SIDEBAR_COLS / EXPAND_COLS / COMMIT_COLS / SETTINGS_COLS
#                    / LAYOUT_MODE
#
# 测试钩子:HERDR_LAZYGIT_GEN_SH / HERDR_LAZYGIT_FREE_KEYS 可覆盖
# gen-config-layer.sh / free-keys.py 的路径(自测用,平时不用设)。
#
# 隐藏子命令:settings-fzf.sh preview <菜单项> —— 供 fzf --preview 回调自身。
#
# bash 3.2 兼容(macOS 默认);复杂解析用 python3,不引第三方库(fzf 除外)。
set -euo pipefail

# ---------------------------------------------------------------------------
# 依赖检查:没有 fzf 就给出安装指引并退出
# ---------------------------------------------------------------------------
if ! command -v fzf >/dev/null 2>&1; then
  cat >&2 <<'EOF'
settings-fzf.sh: 缺少 fzf(设置页的菜单引擎)。

安装方式(任选其一):
  brew install fzf
  bash "<插件目录>/scripts/ensure-fzf.sh"
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# 常量与路径
# ---------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SELF="$script_dir/settings-fzf.sh"
AI_SH="$script_dir/ai-commit-msg.sh"
GEN_SH="${HERDR_LAZYGIT_GEN_SH:-$script_dir/gen-config-layer.sh}"
FREE_KEYS_PY="${HERDR_LAZYGIT_FREE_KEYS:-$script_dir/free-keys.py}"

# 插件三动词的默认键——必须与 gen-config-layer.sh 的 def_commit/def_zoom/
# def_settings 保持同一组值(那边是生成层的唯一真相,这里只做展示与比对)
DEF_KEY_COMMIT='C'
DEF_KEY_ZOOM='U'
DEF_KEY_SETTINGS=';'

CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
AI_CONF="$CONFIG_DIR/ai-backend.conf"
KEYS_CONF="$CONFIG_DIR/keys.conf"
PANEL_CONF="$CONFIG_DIR/panel.conf"

KEYS_CONF_HEADER='# keys.conf — herdr-lazygit 插件三动词的键位(设置页写入,gen-config-layer.sh 读取)。
# 只存插件动词的键;想重映射 lazygit 内置键请编辑 lazygit-user.yml。'
PANEL_CONF_HEADER='# panel.conf — herdr-lazygit 面板几何与布局状态。设置页和布局脚本写入。'

MSG=""        # 上一步操作的结果,显示在主菜单 header 里
GEN_NOTE=""   # regen 的结果说明(拼进 MSG)

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

# 读入全部 conf(先设默认值再 source,模型默认值与 ai-commit-msg.sh 保持一致)
load_confs() {
  AI_BACKEND="auto"; AI_CUSTOM_CMD=""
  AI_CLAUDE_MODEL="haiku"; AI_CODEX_MODEL=""
  AI_OPENCODE_MODEL="google/gemini-2.5-flash"; AI_GEMINI_MODEL=""
  KEY_COMMIT=""; KEY_ZOOM=""; KEY_SETTINGS=""
  SIDEBAR_COLS=""; EXPAND_COLS=""; COMMIT_COLS=""; SETTINGS_COLS=""
  LAYOUT_MODE="sidebar"
  # shellcheck disable=SC1090
  { [ -f "$AI_CONF" ] && . "$AI_CONF"; } || true
  # shellcheck disable=SC1090
  { [ -f "$KEYS_CONF" ] && . "$KEYS_CONF"; } || true
  # shellcheck disable=SC1090
  { [ -f "$PANEL_CONF" ] && . "$PANEL_CONF"; } || true
}

# AI_BACKEND=auto 时按 ai-commit-msg.sh 的探测顺序解析出实际后端
resolved_backend() {
  local b="$AI_BACKEND" c
  if [ "$b" = "auto" ]; then
    b=""
    for c in claude codex opencode gemini; do
      if command -v "$c" >/dev/null 2>&1; then b="$c"; break; fi
    done
  fi
  printf '%s' "$b"
}

# 首次创建 conf 时写入文件头注释
seed_conf() {
  # $1=文件 $2=头部注释
  [ -f "$1" ] && return 0
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$2" > "$1"
}

# 更新 conf 里的单个 KEY=VALUE,保留其他行;值以单引号安全转义写入
# (与 ai-commit-msg.sh 的 write_conf_var 同款,但文件路径作参数)
conf_set() {
  local file="$1" key="$2" value="$3" tmp
  mkdir -p "$CONFIG_DIR"
  tmp="$(mktemp "${TMPDIR:-/tmp}/herdr-lazygit.conf.XXXXXX")"
  if [ -f "$file" ]; then
    grep -v "^${key}=" "$file" > "$tmp" || true
  fi
  printf "%s='%s'\n" "$key" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")" >> "$tmp"
  mv "$tmp" "$file"
}

# 从 conf 里删掉某个 KEY(= 恢复默认)
conf_del() {
  local file="$1" key="$2" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/herdr-lazygit.conf.XXXXXX")"
  grep -v "^${key}=" "$file" > "$tmp" || true
  mv "$tmp" "$file"
}

# 调生成层重建 generated.yml;脚本未就绪时容错跳过并在 GEN_NOTE 里提示
regen() {
  if [ -f "$GEN_SH" ]; then
    if bash "$GEN_SH" >/dev/null 2>&1; then
      GEN_NOTE="已重新生成 generated.yml"
    else
      GEN_NOTE="gen-config-layer.sh 执行失败(conf 已写入,可手动重跑排查)"
    fi
  else
    GEN_NOTE="生成层脚本未就绪,跳过重新生成(conf 已写入)"
  fi
}

pause() {
  printf '\n按任意键返回菜单...'
  IFS= read -rsn1 _ || true
  printf '\n'
}

menu_items() {
  cat <<'EOF'
AI 后端
AI 模型
AI Prompt
键位:Commit
键位:展开
键位:Settings
侧栏宽度
展开宽度
AI 提交窗宽度
EOF
}

# ---------------------------------------------------------------------------
# preview 子命令:主菜单右侧/下方的"当前值 + 说明"(fzf --preview 回调)
# ---------------------------------------------------------------------------
cmd_preview() {
  load_confs
  local item="${1:-}" b m pf
  case "$item" in
    "AI 后端")
      b="$(resolved_backend)"
      printf '当前:%s' "$AI_BACKEND"
      [ "$AI_BACKEND" = "auto" ] && printf '(解析为 %s)' "${b:-无可用后端}"
      printf '\n\n'
      "$AI_SH" backends 2>/dev/null | awk -F'\t' '{printf "  %-10s %s\n", $1, $2}'
      printf '\n说明:生成 commit message 用的 AI CLI。auto 按\nclaude>codex>opencode>gemini 顺序自动探测;custom 需在\nai-backend.conf 里配置 AI_CUSTOM_CMD。\n'
      ;;
    "AI 模型")
      b="$(resolved_backend)"
      case "$b" in
        claude)   m="$AI_CLAUDE_MODEL" ;;
        codex)    m="$AI_CODEX_MODEL" ;;
        opencode) m="$AI_OPENCODE_MODEL" ;;
        gemini)   m="$AI_GEMINI_MODEL" ;;
        *)        m="" ;;
      esac
      printf '当前后端:%s\n' "${b:-（无可用后端）}"
      printf '当前模型:%s\n\n' "${m:-（跟随 CLI 默认）}"
      printf '说明:commit message 是小活,默认刻意用便宜/快的档。\n列表选择或手动输入模型 id;custom 后端不支持选模型。\n'
      ;;
    "AI Prompt")
      pf="$CONFIG_DIR/prompt.txt"
      if [ -s "$pf" ]; then
        printf '文件:%s\n──────\n' "$pf"
        head -8 "$pf"
        printf '\n说明:用 $EDITOR 编辑生成 commit message 的 prompt,保存即生效。\n'
      else
        printf '尚未自定义(使用内置 prompt)。\n\n说明:Enter 后用 $EDITOR 打开,首次会以内置 prompt 播种。\n'
      fi
      ;;
    "键位:Commit")
      printf '当前:%s\n\n' "${KEY_COMMIT:-${DEF_KEY_COMMIT}(插件默认)}"
      printf '说明:files 面板里触发 AI commit message 全流程。\n默认 C 遮蔽 lazygit 低频内置「用 git editor 提交」。\n改键会经 free-keys.py 校验,与内置键冲突将被拒绝。\n'
      ;;
    "键位:展开")
      printf '当前:%s\n\n' "${KEY_ZOOM:-${DEF_KEY_ZOOM}(插件默认)}"
      printf '说明:全局切换 lazygit 的侧栏/展开布局。\n改键会经 free-keys.py 校验,与内置键冲突将被拒绝。\n'
      ;;
    "键位:Settings")
      printf '当前:%s\n\n' "${KEY_SETTINGS:-${DEF_KEY_SETTINGS}(插件默认)}"
      printf '说明:全局键,打开本设置页。\n改键会经 free-keys.py 校验,与内置键冲突将被拒绝。\n'
      ;;
    "侧栏宽度")
      if [ -n "$SIDEBAR_COLS" ]; then
        printf '当前:%s 列\n\n' "$SIDEBAR_COLS"
      else
        printf '当前:42 列(默认)\n\n'
      fi
      printf '说明:lazygit 侧栏 pane 的列数(panel.conf 的 SIDEBAR_COLS)。\n辅助 pane 关闭或 U 收起时会还原到这个宽度。\n'
      ;;
    "展开宽度")
      if [ -n "$EXPAND_COLS" ]; then
        printf '当前:%s 列\n\n' "$EXPAND_COLS"
      else
        printf '当前:110 列(默认)\n\n'
      fi
      printf '说明:按展开键后 lazygit pane 的目标列数(panel.conf 的 EXPAND_COLS)。\n实际值会限制在 tab 总宽减 20 列以内。\n'
      ;;
    "AI 提交窗宽度")
      if [ -n "$COMMIT_COLS" ]; then
        printf '当前:%s 列\n\n' "$COMMIT_COLS"
      else
        printf '当前:70 列(默认)\n\n'
      fi
      printf '说明:AI commit 生成、编辑 pane 的列数(panel.conf 的 COMMIT_COLS)。\n'
      ;;
    *)
      printf '(无预览)\n'
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 子流程:AI 后端(fzf 列表,数据来自 ai-commit-msg.sh backends)
# ---------------------------------------------------------------------------
flow_backend() {
  local line name out rc
  line="$("$AI_SH" backends 2>/dev/null | fzf \
      --layout=reverse --no-multi --cycle --tabstop=12 \
      --prompt='AI 后端 > ' \
      --header='Enter/双击 = 选择 · Esc = 返回' \
      --bind 'double-click:accept')" && rc=0 || rc=$?
  [ "$rc" -ne 0 ] && { MSG="已取消"; return 0; }
  name="$(printf '%s' "$line" | cut -f1)"
  [ -n "$name" ] || { MSG="已取消"; return 0; }
  if out="$("$AI_SH" set-backend "$name" 2>&1)"; then
    regen
    MSG="$out · $GEN_NOTE"
  else
    printf '%s\n' "$out"
    pause
    MSG="切换后端失败(见上方提示)"
  fi
}

# ---------------------------------------------------------------------------
# 子流程:AI 模型(fzf 列表 + --print-query 支持手动输入模型 id)
# ---------------------------------------------------------------------------
flow_model() {
  local out rc query sel value setout
  out="$("$AI_SH" models 2>/dev/null | fzf \
      --layout=reverse --no-multi --print-query \
      --prompt='AI 模型 > ' \
      --header='Enter = 选择;列表没有的直接输入 id 再 Enter · Esc = 返回' \
      --bind 'double-click:accept')" && rc=0 || rc=$?
  # rc=1 是"无匹配但有输入"(--print-query 仍输出 query 行);rc>=2 才是取消/出错
  if [ "$rc" -ge 2 ]; then MSG="已取消"; return 0; fi
  query="$(printf '%s\n' "$out" | sed -n 1p)"
  sel="$(printf '%s\n' "$out" | sed -n 2p)"
  value="${sel:-$query}"
  [ -n "$value" ] || { MSG="已取消"; return 0; }
  if setout="$("$AI_SH" set-model "$value" 2>&1)"; then
    regen
    MSG="$setout · $GEN_NOTE"
  else
    printf '%s\n' "$setout"
    pause
    MSG="设置模型失败(见上方提示)"
  fi
}

# ---------------------------------------------------------------------------
# 子流程:AI Prompt($EDITOR 打开 prompt 文件)
# ---------------------------------------------------------------------------
flow_prompt() {
  local pf
  pf="$("$AI_SH" prompt-file)"
  # EDITOR 可能带参数(如 "code -w"),按惯例不加引号让它分词
  # shellcheck disable=SC2086
  ${EDITOR:-vi} "$pf" || true
  regen
  MSG="prompt 已保存:$pf · $GEN_NOTE"
}

# ---------------------------------------------------------------------------
# 子流程:改键位(read -rsn1 抓一个键,free-keys.py check 校验冲突)
# 用法:flow_key <keys.conf 变量名> <默认键> <显示名> <free-keys 校验的 context...>
# ---------------------------------------------------------------------------
flow_key() {
  local var="$1" def="$2" label="$3"; shift 3
  local cur key notation out stty_saved
  load_confs
  cur="$(eval "printf '%s' \"\$$var\"")"
  cur="${cur:-$def}"
  clear
  printf '修改 [键位:%s]  (当前:%s)\n\n' "$label" "$cur"
  printf '请按下新键 —— 支持字母/数字/符号,以及 Ctrl 组合(记作 <c-x>)。\n'
  printf 'Esc = 取消。插件键不得遮蔽 lazygit 常用内置键,冲突会被拒绝。\n\n'
  # 关闭流控让 Ctrl-S / Ctrl-Q 可被读到,读完恢复终端设置
  stty_saved="$(stty -g 2>/dev/null || true)"
  stty -ixon 2>/dev/null || true
  IFS= read -rsn1 key || key=$'\x1b'
  [ -n "$stty_saved" ] && stty "$stty_saved" 2>/dev/null || true
  if [ "$key" = $'\x1b' ]; then
    # Esc 本身,或方向键等多字节转义序列:排掉残余字节后取消
    while IFS= read -rsn1 -t 1 _; do :; done
    MSG="已取消"
    return 0
  fi
  if [ -z "$key" ]; then
    MSG="Enter 不能设为插件键,已取消"
    return 0
  fi
  # 单字节 → lazygit 键位记法:可打印字符原样;Ctrl 组合记作 <c-x>;
  # 空格/DEL 等一律拒绝(空格是 lazygit 的 stage 键)
  notation="$(printf '%s' "$key" | python3 -c '
import sys
b = sys.stdin.buffer.read()
if len(b) == 1:
    c = b[0]
    if 33 <= c <= 126:
        sys.stdout.write(chr(c))
    elif 1 <= c <= 26:
        sys.stdout.write("<c-%s>" % chr(c + 96))
')"
  if [ -z "$notation" ]; then
    MSG="不支持的按键,已取消"
    return 0
  fi
  # 新键 == 当前键:直接放行不走 check(free-keys.py 文档字符串约定——
  # 否则默认 C 这类"已接受的例外"会被自己的占用记录拒掉,永远改不回去)
  if [ "$notation" = "$cur" ]; then
    MSG="[键位:$label] 与当前键相同($notation),未变化"
    return 0
  fi
  # 冲突校验:free-keys.py check KEY context...(非零退出 = 冲突/不可用)
  local check_note=""
  if [ -f "$FREE_KEYS_PY" ]; then
    if out="$(python3 "$FREE_KEYS_PY" check "$notation" "$@" 2>&1)"; then
      :
    else
      printf '键 %s 与 lazygit 内置绑定冲突,已拒绝:\n%s\n' "$notation" "$out"
      pause
      MSG="[键位:$label] 改键被拒绝:$notation 已被占用"
      return 0
    fi
  else
    check_note="(free-keys.py 未就绪,未校验冲突)"
  fi
  seed_conf "$KEYS_CONF" "$KEYS_CONF_HEADER"
  conf_set "$KEYS_CONF" "$var" "$notation"
  regen
  MSG="[键位:$label] 已设为 $notation$check_note · $GEN_NOTE"
}

# ---------------------------------------------------------------------------
# 子流程:宽度(read 数字校验,写 panel.conf;留空 = 删除该项恢复默认)
# 用法:flow_width <panel.conf 变量名> <显示名> <当前值描述> [最小值]
# ---------------------------------------------------------------------------
flow_width() {
  local var="$1" label="$2" cur="$3" min="${4:-20}" val
  clear
  printf '修改 [%s]  (当前:%s)\n\n' "$label" "$cur"
  printf '输入新列数(纯数字,%s–500;留空 = 恢复默认),Enter 确认:\n> ' "$min"
  IFS= read -r val || { MSG="已取消"; return 0; }
  if [ -z "$val" ]; then
    conf_del "$PANEL_CONF" "$var"
    regen
    MSG="[$label] 已恢复默认 · $GEN_NOTE"
    return 0
  fi
  case "$val" in
    *[!0-9]*) MSG="[$label] 输入无效(需要纯数字),未修改"; return 0 ;;
  esac
  if [ "$val" -lt "$min" ] || [ "$val" -gt 500 ]; then
    MSG="[$label] $val 超出范围($min–500),未修改"
    return 0
  fi
  seed_conf "$PANEL_CONF" "$PANEL_CONF_HEADER"
  conf_set "$PANEL_CONF" "$var" "$val"
  regen
  MSG="[$label] 已设为 $val 列 · $GEN_NOTE"
}

# ---------------------------------------------------------------------------
# 主菜单循环
# ---------------------------------------------------------------------------
main_menu() {
  local header item
  while true; do
    header='改动在切回 lazygit pane 时自动生效(热重载)
Enter/双击 = 修改 · Esc/q = 退出'
    if [ -n "$MSG" ]; then
      header="$header
✔ $MSG"
    fi
    item="$(menu_items | fzf \
        --layout=reverse --no-multi --cycle \
        --prompt='lazygit 设置 > ' \
        --header="$header" \
        --preview="bash $(printf %q "$SELF") preview {}" \
        --preview-window='down,45%,wrap' \
        --bind 'double-click:accept' \
        --bind 'q:abort')" || return 0
    MSG=""
    case "$item" in
      "AI 后端")       flow_backend ;;
      "AI 模型")       flow_model ;;
      "AI Prompt")     flow_prompt ;;
      "键位:Commit")  flow_key KEY_COMMIT "$DEF_KEY_COMMIT" "Commit" files ;;
      "键位:展开")    flow_key KEY_ZOOM "$DEF_KEY_ZOOM" "展开" global ;;
      "键位:Settings") flow_key KEY_SETTINGS "$DEF_KEY_SETTINGS" "Settings" global ;;
      "侧栏宽度")
        load_confs
        flow_width SIDEBAR_COLS "侧栏宽度" "${SIDEBAR_COLS:-42(默认)}"
        ;;
      "展开宽度")
        load_confs
        flow_width EXPAND_COLS "展开宽度" "${EXPAND_COLS:-110(默认)}" 80
        ;;
      "AI 提交窗宽度")
        load_confs
        flow_width COMMIT_COLS "AI 提交窗宽度" "${COMMIT_COLS:-70(默认)}" 40
        ;;
      "") return 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
case "${1:-menu}" in
  preview) cmd_preview "${2:-}" ;;
  menu)    main_menu ;;
  *)
    echo "用法: settings-fzf.sh [preview <菜单项>]" >&2
    exit 1
    ;;
esac
