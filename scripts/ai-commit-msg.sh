#!/usr/bin/env bash
# ai-commit-msg.sh — AI-generated conventional commit messages for the
# herdr-lazygit plugin.
#
# Subcommands:
#   candidates        Read the staged diff and output up to 3 commit-message
#                     candidates, one per line.
#   backends          Output "name<TAB>status" per line
#                     (detected/missing/current).
#   set-backend NAME  Write the backend to the configuration file
#                     (auto|claude|codex|opencode|gemini|custom).
#
# Configuration file: $HERDR_PLUGIN_CONFIG_DIR/ai-backend.conf
# (shell-sourceable format)
#   AI_BACKEND=auto|claude|codex|opencode|gemini|custom
#   AI_CUSTOM_CMD="..."   # custom: stdin receives prompt+diff; stdout emits message
#
# bash 3.2 compatible (macOS default). JSON/text processing uses python3,
# without jq.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants and configuration
# ---------------------------------------------------------------------------

TIMEOUT_SEC="${AI_TIMEOUT_SEC:-60}"
DIFF_MAX_CHARS="${DIFF_MAX_CHARS:-8000}"
BACKEND_ORDER="claude codex opencode gemini"   # auto detection order

# Per-backend models: commit messages are a small task, so defaults deliberately
# favor cheap, fast models instead of inheriting a user's CLI default (which may
# be the most expensive tier with high reasoning effort). Override these in
# ai-backend.conf; an empty string falls back to that CLI's own default.
AI_CLAUDE_MODEL="${AI_CLAUDE_MODEL-haiku}"
AI_CODEX_MODEL="${AI_CODEX_MODEL-}"   # empty = Codex default (no stable, broadly accepted cheap model ID; do not guess)
AI_OPENCODE_MODEL="${AI_OPENCODE_MODEL-google/gemini-2.5-flash}"
AI_GEMINI_MODEL="${AI_GEMINI_MODEL-gemini-2.5-flash}"

CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
CONFIG_FILE="$CONFIG_DIR/ai-backend.conf"

MSG_NO_STAGED="(nothing staged — stage files with Space first)"
MSG_NO_BACKEND="(no available AI CLI found: claude/codex/opencode/gemini)"
MSG_NO_CUSTOM_CMD="(custom backend has no AI_CUSTOM_CMD — edit ai-backend.conf or choose another backend in Settings)"
MSG_TIMEOUT="(AI generation timed out; retry or choose another backend)"
MSG_FAILED="(AI generation failed; check the backend login or choose another backend)"
MSG_DIFF_PREP_FAILED="(failed to prepare the staged diff for AI commit generation)"

PROMPT='Generate up to 3 alternative conventional commit messages (feat/fix/docs/refactor/chore/test/perf/build/ci/style) for the following git diff. Output ONLY the commit messages, one per line, at most 3 lines. Each message must be a single line in English with a subject of at most 72 characters. No numbering, no bullets, no markdown, no quotes, no explanations.'

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

# AI_BACKEND from the environment overrides the configuration file (useful for
# temporary switching and tests).
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
  # A nonempty user prompt (edited through Settings) overrides the built-in one.
  if [ -s "$CONFIG_DIR/prompt.txt" ]; then
    PROMPT="$(cat "$CONFIG_DIR/prompt.txt")"
  fi
}

# Update one KEY=VALUE in the conf file while preserving other lines. An early
# set-backend implementation rewrote the whole conf and dropped other keys, so
# all updates now go through this helper. Values are safely escaped and written
# in single quotes.
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

# Run a command with a timeout, passing stdin and stdout through. stderr is
# discarded by default, or written to AI_ERR_FILE when set so a diagnostic can
# be extracted after failure. A timeout exits 124; otherwise preserve the child
# process's exit code.
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

# Extract a short one-line diagnostic from a stderr file (strip ANSI, prefer a
# line containing Error/error, and truncate it).
stderr_hint() {
  # $1 = stderr file path
  [ -s "${1:-}" ] || return 0
  python3 -c '
import re, sys
try:
    data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
except OSError:
    sys.exit(0)
data = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", data)   # strip ANSI escapes
lines = [l.strip() for l in data.splitlines() if l.strip()]
if not lines:
    sys.exit(0)
pick = next((l for l in lines if re.search(r"error", l, re.I)), lines[-1])
if len(pick) > 80:
    pick = pick[:77] + "..."
sys.stdout.write(pick)
' "$1"
}

# Sanitize model output: remove Markdown fences, surrounding quotes, blank
# lines, "commit message:" prefixes, and numbering; keep at most 3 lines.
sanitize_output() {
  python3 -c '
import re, sys
out = []
for line in sys.stdin.read().splitlines():
    s = line.strip()
    if not s or s.startswith("```") or s.startswith("~~~"):
        continue
    s = s.strip("`\"\x27 \t")       # strip backticks/double/single quotes first (\x27 = single quote)
    s = re.sub(r"(?i)^(commit\s+messages?|messages?|candidates?)\s*[::]\s*", "", s)
    s = re.sub(r"^\d+\s*[.)::]\s*", "", s)   # numbering such as 1. / 2)
    s = re.sub(r"^[-*+]\s+", "", s)          # list markers
    s = s.strip("`\"\x27 \t").strip()
    if not s:
        continue
    out.append(s)
    if len(out) == 3:
        break
sys.stdout.write("\n".join(out))
'
}

# Build the exact staged-diff payload passed to the AI CLI. Small diffs go
# through unchanged; large diffs become a structured sample with a complete
# per-file overview, a fair round-robin hunk sample, and a coverage note.
build_ai_diff_payload() {
  python3 - "$DIFF_MAX_CHARS" <<'PY'
import os
import subprocess
import sys

limit = int(sys.argv[1])
lockfiles = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock"}
coverage_text = "input is a sample of the staged diff"
coverage_placeholder = (
    "\nCOVERAGE: sampled 9999/9999 files, 99999/99999 hunks; "
    + coverage_text
    + "\n"
)
patch_section_header = "\nPATCH SAMPLE\n"


def git_bytes(*args):
    return subprocess.check_output(["git"] + list(args), stderr=subprocess.DEVNULL)


def git_text(*args):
    return git_bytes(*args).decode("utf-8", "replace")


def parse_name_status():
    data = git_bytes("diff", "--cached", "--name-status", "-z", "--find-renames")
    parts = data.decode("utf-8", "replace").split("\0")
    if parts and parts[-1] == "":
        parts.pop()
    entries = []
    i = 0
    while i < len(parts):
        status = parts[i]
        i += 1
        code = status[:1]
        old_path = ""
        path = ""
        if code in ("R", "C") and i + 1 < len(parts):
            old_path = parts[i]
            path = parts[i + 1]
            i += 2
        elif i < len(parts):
            path = parts[i]
            i += 1
        else:
            break
        display = path if not old_path or old_path == path else old_path + " -> " + path
        entries.append(
            {
                "status": status,
                "path": path,
                "old_path": old_path,
                "display": display,
            }
        )
    return entries


def parse_numstat():
    data = git_bytes("diff", "--cached", "--numstat", "-z", "--find-renames")
    entries = []
    i = 0
    size = len(data)
    while i < size:
        tab1 = data.find(b"\t", i)
        if tab1 == -1:
            break
        added_raw = data[i:tab1].decode("utf-8", "replace")
        i = tab1 + 1

        tab2 = data.find(b"\t", i)
        if tab2 == -1:
            break
        deleted_raw = data[i:tab2].decode("utf-8", "replace")
        i = tab2 + 1

        old_path = ""
        if i < size and data[i:i + 1] == b"\0":
            i += 1
            nul = data.find(b"\0", i)
            if nul == -1:
                break
            old_path = data[i:nul].decode("utf-8", "replace")
            i = nul + 1

            nul = data.find(b"\0", i)
            if nul == -1:
                break
            path = data[i:nul].decode("utf-8", "replace")
            i = nul + 1
        else:
            nul = data.find(b"\0", i)
            if nul == -1:
                path = data[i:].decode("utf-8", "replace")
                i = size
            else:
                path = data[i:nul].decode("utf-8", "replace")
                i = nul + 1

        binary = added_raw == "-" or deleted_raw == "-"
        entries.append(
            {
                "path": path,
                "old_path": old_path,
                "added": None if binary else int(added_raw),
                "deleted": None if binary else int(deleted_raw),
                "binary": binary,
            }
        )
    return entries


def is_deprioritized(path, binary):
    base = os.path.basename(path)
    return (
        binary
        or base in lockfiles
        or path.endswith(".min.js")
        or path.endswith(".min.css")
    )


def split_patch(patch_text):
    if not patch_text:
        return "", []
    lines = patch_text.splitlines(True)
    header = []
    hunks = []
    current = None
    for line in lines:
        if line.startswith("@@"):
            current = [line]
            hunks.append(current)
        elif current is None:
            header.append(line)
        else:
            current.append(line)
    if hunks:
        return "".join(header), ["".join(hunk) for hunk in hunks]
    return "", [patch_text]


def load_patch_text(path, old_path):
    candidates = []
    if path:
        candidates.append(path)
    if old_path and old_path != path:
        candidates.append(old_path)
    for candidate in candidates:
        patch_text = git_text("diff", "--cached", "-U2", "--", candidate)
        if patch_text:
            return patch_text
    return ""


def render_overview(files, total_added, total_deleted, binary_files):
    total_line = "total: %d files, +%d -%d" % (len(files), total_added, total_deleted)
    if binary_files:
        total_line += ", %d binary" % binary_files
    lines = ["STAGED DIFF OVERVIEW", total_line]
    for entry in files:
        if entry["binary"]:
            count_text = "binary"
        else:
            count_text = "+%d -%d" % (entry["added"], entry["deleted"])
        lines.append("%s %s %s" % (entry["status"], count_text, entry["display"]))
    return "\n".join(lines) + "\n"


def select_hunks(files, budget):
    def round_robin(group, remaining):
        while remaining > 0:
            progressed = False
            for entry in group:
                if entry["cursor"] >= len(entry["chunks"]):
                    continue
                chunk_index = entry["cursor"]
                chunk_text = entry["chunks"][chunk_index]
                extra = 0
                if not entry["selected"] and entry["header"]:
                    extra = len(entry["header"])
                cost = len(chunk_text) + extra
                if cost <= remaining:
                    entry["selected"].append(chunk_index)
                    entry["cursor"] += 1
                    remaining -= cost
                    progressed = True
                else:
                    continue
            if not progressed:
                break
        return remaining

    normal = [entry for entry in files if entry["chunks"] and not entry["deprioritized"]]
    remaining_budget = round_robin(normal, budget)
    deprioritized = [entry for entry in files if entry["chunks"] and entry["deprioritized"]]
    remaining_budget = round_robin(deprioritized, remaining_budget)
    return remaining_budget


def render_output(files, overview_text):
    patch_blocks = []
    sampled_files = 0
    sampled_hunks = 0
    total_hunks = sum(len(entry["chunks"]) for entry in files)
    for entry in files:
        if not entry["selected"]:
            continue
        sampled_files += 1
        sampled_hunks += len(entry["selected"])
        block = ""
        if entry["header"]:
            block += entry["header"]
        block += "".join(entry["chunks"][idx] for idx in entry["selected"])
        patch_blocks.append(block)

    coverage_note = (
        "COVERAGE: sampled %d/%d files, %d/%d hunks; %s\n"
        % (sampled_files, len(files), sampled_hunks, total_hunks, coverage_text)
    )

    pieces = [overview_text]
    if patch_blocks:
        pieces.append(patch_section_header)
        pieces.append("".join(patch_blocks))
        if not patch_blocks[-1].endswith("\n"):
            pieces.append("\n")
    pieces.append("\n")
    pieces.append(coverage_note)
    return "".join(pieces)


def drop_last_chunk(files):
    for entry in reversed(files):
        if entry["selected"]:
            entry["selected"].pop()
            return True
    return False


full_diff = git_text("diff", "--cached")
if len(full_diff) <= limit:
    sys.stdout.write(full_diff)
    sys.exit(0)

name_entries = parse_name_status()
numstat_entries = parse_numstat()
file_count = max(len(name_entries), len(numstat_entries))
files = []
total_added = 0
total_deleted = 0
binary_files = 0

for idx in range(file_count):
    name_entry = name_entries[idx] if idx < len(name_entries) else {}
    num_entry = numstat_entries[idx] if idx < len(numstat_entries) else {}

    path = name_entry.get("path") or num_entry.get("path") or ""
    old_path = name_entry.get("old_path") or num_entry.get("old_path") or ""
    if not path:
        continue

    status = name_entry.get("status", "?")
    display = name_entry.get("display") or (old_path + " -> " + path if old_path and old_path != path else path)
    binary = bool(num_entry.get("binary"))
    added = num_entry.get("added")
    deleted = num_entry.get("deleted")
    if binary:
        binary_files += 1
    else:
        total_added += int(added or 0)
        total_deleted += int(deleted or 0)

    patch_text = load_patch_text(path, old_path)
    header, chunks = split_patch(patch_text)
    files.append(
        {
            "status": status,
            "display": display,
            "path": path,
            "old_path": old_path,
            "added": added or 0,
            "deleted": deleted or 0,
            "binary": binary,
            "deprioritized": is_deprioritized(path, binary),
            "header": header,
            "chunks": chunks,
            "cursor": 0,
            "selected": [],
        }
    )

overview_text = render_overview(files, total_added, total_deleted, binary_files)
patch_budget = limit - len(overview_text) - len(patch_section_header) - len(coverage_placeholder)
if patch_budget > 0:
    select_hunks(files, patch_budget)

assembled = render_output(files, overview_text)
while len(assembled) > limit and drop_last_chunk(files):
    assembled = render_output(files, overview_text)

sys.stdout.write(assembled)
PY
}

# ---------------------------------------------------------------------------
# Backend invocations (diff through stdin, prompt through argv; see the Spike
# for verified behavior).
# ---------------------------------------------------------------------------

gen_claude() {
  # Do not add --bare: this version then fails to read keychain credentials and
  # reports Not logged in. Pass --model explicitly (haiku by default) to avoid
  # inheriting an expensive CLI default.
  if [ -n "$AI_CLAUDE_MODEL" ]; then
    run_with_timeout claude -p --model "$AI_CLAUDE_MODEL" "$PROMPT"
  else
    run_with_timeout claude -p "$PROMPT"
  fi
}

gen_opencode() {
  # The default model is unavailable, so -m is required explicitly. stderr
  # (banner/ANSI) is discarded by run_with_timeout.
  run_with_timeout opencode run -m "${AI_OPENCODE_MODEL:-google/gemini-2.5-flash}" "$PROMPT"
}

gen_codex() {
  # Reading the final message from the -o file is most reliable; stdout is not
  # guaranteed to contain only the message over time.
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
  if [ -n "$AI_GEMINI_MODEL" ]; then
    run_with_timeout gemini -m "$AI_GEMINI_MODEL" -p "$PROMPT"
  else
    run_with_timeout gemini -p "$PROMPT"
  fi
}

gen_custom() {
  # Contract: stdin receives prompt+diff; stdout emits the message.
  local diff_text
  diff_text="$(cat)"
  printf '%s\n\n%s' "$PROMPT" "$diff_text" | run_with_timeout sh -c "$AI_CUSTOM_CMD"
}

# ---------------------------------------------------------------------------
# Backend resolution
# ---------------------------------------------------------------------------

# Output the resolved backend name, or an empty string if resolution fails.
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
# Subcommand: candidates
# ---------------------------------------------------------------------------

cmd_candidates() {
  load_config

  local diff backend raw rc result
  if git diff --cached --quiet --exit-code 2>/dev/null; then
    printf '%s\n' "$MSG_NO_STAGED"
    return 0
  fi

  if [ "${HERDR_LAZYGIT_TEST_PRINT_AI_INPUT:-}" = "1" ]; then
    build_ai_diff_payload
    return 0
  fi

  diff="$(build_ai_diff_payload)" || {
    printf '%s\n' "$MSG_DIFF_PREP_FAILED"
    return 0
  }

  backend="$(resolve_backend)"
  if [ -z "$backend" ]; then
    # Distinguish the reason from the configuration instead of always claiming
    # no AI CLI was found.
    case "$AI_BACKEND" in
      custom) printf '%s\n' "$MSG_NO_CUSTOM_CMD" ;;
      auto)   printf '%s\n' "$MSG_NO_BACKEND" ;;
      *)      printf '(current backend %s is not installed — choose another backend in Settings)\n' "$AI_BACKEND" ;;
    esac
    return 0
  fi

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
    # Include the backend name and one stderr summary line on failure (such as
    # Gemini's IneligibleTierError). A generic failure alone gives the user no
    # way to diagnose login or eligibility problems.
    hint="$(stderr_hint "$err_file" || true)"
    rm -f "$err_file"
    if [ -n "$hint" ]; then
      printf '(AI generation failed [%s]: %s — check the backend login or choose another backend)\n' "$backend" "$hint"
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
# Subcommand: backends
# ---------------------------------------------------------------------------

cmd_backends() {
  load_config
  local b status
  # Include an auto row so the menu can switch back to automatic detection.
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
# Subcommand: set-backend NAME
# ---------------------------------------------------------------------------

cmd_set_backend() {
  local name="${1:-}"
  case "$name" in
    auto|claude|codex|opencode|gemini|custom) ;;
    *)
      echo "Usage: ai-commit-msg.sh set-backend auto|claude|codex|opencode|gemini|custom" >&2
      return 1
      ;;
  esac

  load_config
  # A custom backend requires AI_CUSTOM_CMD first. Otherwise candidates always
  # fails, and its error could misleadingly imply that no AI CLI is installed.
  if [ "$name" = "custom" ] && [ -z "$AI_CUSTOM_CMD" ]; then
    echo "Cannot switch to the custom backend: AI_CUSTOM_CMD is not configured." >&2
    echo "First add a line to $CONFIG_FILE, for example:" >&2
    echo "  AI_CUSTOM_CMD='my-ai-cli --flag'   # stdin receives prompt+diff; stdout emits message" >&2
    echo "Then run set-backend custom again." >&2
    return 1
  fi
  write_conf_var AI_BACKEND "$name"
  echo "AI backend set to: $name"
}

# Current backend name (resolved when auto); output empty for custom or when no
# backend is available.
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

# models — output model candidates for the current backend, one per line (menu
# data source). The current value comes first. Fetch dynamic lists where
# supported (opencode); otherwise provide commonly used tiers.
cmd_models() {
  local backend cur
  # Load the configuration in this scope first. current_model_backend sources
  # it inside command substitution (a subshell), so its AI_<BACKEND>_MODEL
  # values do not propagate here. Without this explicit load, the code below
  # would always read the hard-coded defaults at the top of the file (such as
  # haiku), making the Settings model picker mislabel the current model.
  load_config
  backend="$(current_model_backend)"
  if [ -z "$backend" ]; then
    echo "(current backend does not support model selection — edit AI_CUSTOM_CMD directly for custom backends)"
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
      # No public listing command; provide a placeholder that users replace
      # with a real ID in the next input field.
      echo "(enter a model ID in the next input; blank = use CLI default)" ;;
  esac | grep -v "^${cur}\$" || true
}

# set-model VALUE — write the model for the current backend (empty = use that
# CLI's own default).
cmd_set_model() {
  local value="${1:-}" backend
  backend="$(current_model_backend)"
  if [ -z "$backend" ]; then
    echo "The current backend does not support model selection" >&2
    return 1
  fi
  case "$value" in "("*) echo "Cancelled" ; return 0 ;; esac
  write_conf_var "$(model_var_for "$backend")" "$value"
  echo "$backend model set to: ${value:-(CLI default)}"
}

# prompt-file — ensure the user prompt file exists (seeded from the built-in
# PROMPT on first use), then output its path.
cmd_prompt_file() {
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_DIR/prompt.txt" ]; then
    printf '%s\n' "$PROMPT" > "$CONFIG_DIR/prompt.txt"
  fi
  printf '%s\n' "$CONFIG_DIR/prompt.txt"
}

# ---------------------------------------------------------------------------
# Entry point
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
      echo "Usage: ai-commit-msg.sh candidates|backends|set-backend NAME|models|set-model VALUE|prompt-file" >&2
      return 1
      ;;
  esac
}

main "$@"
