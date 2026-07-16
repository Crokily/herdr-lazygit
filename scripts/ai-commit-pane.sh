#!/usr/bin/env bash
# ai-commit-pane.sh — responsive, editable AI commit UI inside the GitCommit pane.
#
# On opening, show the backend/model and a spinner, then run
# ai-commit-msg.sh candidates in the background. On success, use fzf to select,
# edit, or write a message, then commit directly in the supplied repository.
# Ctrl-C terminates the AI child process and exits during generation.
#
# bash 3.2 compatible (macOS default).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
AI_SH="$script_dir/ai-commit-msg.sh"
repo="${1:-$(pwd)}"
config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
ai_conf="$config_dir/ai-backend.conf"

if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  printf 'herdr-lazygit: not a git repository: %s\n\nPress any key to close...' "$repo" >&2
  IFS= read -rsn1 _ || true
  exit 1
fi
cd "$repo"

# Read only local configuration for the immediate status line; do not call
# model-listing commands that may use the network or run slowly.
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
  custom)   model="custom command" ;;
  *)        model="" ;;
esac
[ -n "$model" ] || model="CLI default"
if [ "$AI_BACKEND" = "auto" ]; then
  backend_text="auto → ${resolved:-no available backend}"
else
  backend_text="$AI_BACKEND"
fi

clear
printf 'herdr-lazygit · AI Commit\nBackend: %s  ·  Model: %s\n\n' "$backend_text" "$model"

if ! command -v fzf >/dev/null 2>&1; then
  cat >&2 <<'EOF'
fzf is required for the AI commit candidate and message editor.

Install it with:
  brew install fzf

Press any key to close...
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
  printf '\r\033[2KAI generation cancelled.\n'
  if [ -n "$ai_pid" ]; then
    kill "$ai_pid" >/dev/null 2>&1 || true
    wait "$ai_pid" >/dev/null 2>&1 || true
    ai_pid=""
  fi
  exit 0
}
trap cleanup EXIT
trap cancel_generation INT TERM

# Pre-render the "About to commit" preview once as static content so the fzf
# preview can simply cat it: one shortstat title line followed by the complete
# staged diff rendered by delta (scrollable). lazygit already shows the file
# tree on the left; this contains only information hidden by single-column
# sidebar mode.
cols="$(tput cols 2>/dev/null || echo 80)"
shortstat="$(git -C "$repo" diff --cached --shortstat | sed 's/^ *//')"
{
  printf '\033[1m%s\033[0m\n\n' "${shortstat:-nothing staged}"
  if command -v delta >/dev/null 2>&1; then
    git -C "$repo" diff --cached | delta --paging=never --width "$((cols > 4 ? cols - 2 : cols))" || true
  else
    git -C "$repo" -c color.diff=always diff --cached || true
  fi
} > "$preview_file" 2>/dev/null || true

# Show the commit size while waiting so the user can start thinking about the
# message during generation.
printf 'About to commit: %s\n\n' "${shortstat:-?}"
printf '⏳ Generating with AI… (Ctrl-C to cancel)'
HERDR_PLUGIN_CONFIG_DIR="$config_dir" bash "$AI_SH" candidates \
  >"$candidates_file" 2>"$error_file" &
ai_pid=$!

frames='|/-\'
tick=0
while kill -0 "$ai_pid" >/dev/null 2>&1; do
  frame="${frames:$((tick % 4)):1}"
  printf '\r%s Generating with AI… (Ctrl-C to cancel)' "$frame"
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
  printf '(AI generation failed%s)\n' "${hint:+: $hint}" > "$candidates_file"
fi

first_line="$(sed -n '1p' "$candidates_file")"
case "$first_line" in
  '('*)
    printf '%s\n\nPress any key to close...' "$first_line"
    IFS= read -rsn1 _ || true
    exit 0
    ;;
esac

if [ -z "$first_line" ]; then
  printf '(AI returned no usable candidates)\n\nPress any key to close...'
  IFS= read -rsn1 _ || true
  exit 0
fi

# Preview: the upper section contains the full selected message (never
# truncated), and the lower section cats the pre-rendered staged diff. fzf
# replaces {} with safe quoting; when filtering empties the list, show a hint
# for writing a message from scratch.
q_preview_file="$(python3 -c 'import shlex,sys; sys.stdout.write(shlex.quote(sys.argv[1]))' "$preview_file")"
preview_cmd='msg={}; if [ -n "$msg" ]; then printf "\033[1m✏ %s\033[0m\n\n" "$msg"; else printf "\033[1m✏ (the input will be used as the message)\033[0m\n\n"; fi; cat '"$q_preview_file"

fzf_out=""
fzf_rc=0
fzf_out="$(fzf --layout=reverse --no-multi --print-query \
  --prompt='Commit message > ' \
  --header='Enter=commit · type to edit/write · Esc=cancel' \
  --wrap --gap 1 --gap-line --highlight-line \
  --preview "$preview_cmd" \
  --preview-window 'down,65%,wrap' \
  --preview-label '─ About to commit ' \
  --bind 'double-click:accept' < "$candidates_file")" || fzf_rc=$?

# Esc/interruption returns >=2. fzf may return 1 when the query remains but no
# item matches; still commit using that query.
if [ "$fzf_rc" -ge 2 ]; then
  exit 0
fi
query="$(printf '%s\n' "$fzf_out" | sed -n '1p')"
selected="$(printf '%s\n' "$fzf_out" | sed -n '2p')"
message="${selected:-$query}"
message="$(printf '%s' "$message" | python3 -c 'import sys; sys.stdout.write(sys.stdin.read().strip())')"
[ -n "$message" ] || exit 0

clear
printf 'Committing: %s\n\n' "$message"
if git -C "$repo" commit -m "$message" >"$commit_out" 2>"$commit_err"; then
  short_hash="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)"
  printf '✓ Committed %s\n%s\n' "$short_hash" "$message"
else
  printf '✗ git commit failed:\n'
  if [ -s "$commit_err" ]; then
    cat "$commit_err"
  else
    cat "$commit_out"
  fi
fi
sleep 2
