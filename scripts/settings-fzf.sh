#!/usr/bin/env bash
# settings-fzf.sh — herdr-lazygit plugin settings page (fzf menu loop).
#
# Usually launched by open-settings-pane.sh in a dedicated herdr pane (which
# manages the geometry), but it can also be run manually in any terminal.
#
# Interaction model:
#   Main menu = fzf list (the preview shows each item's current value and help);
#   Enter / double-click = open the editing flow; Esc / q = exit settings.
#   Within a flow, Esc (or cancelling fzf) discards the change and returns.
#
# Available flows:
#   AI Backend      → fzf list (data: ai-commit-msg.sh backends)
#   AI Model        → fzf list (data: ai-commit-msg.sh models) plus manual input
#                     through --print-query
#   AI Prompt       → open prompt.txt in $EDITOR (ai-commit-msg.sh prompt-file)
#   Keybinding: *   → press a new key (read -rsn1), then validate conflicts with
#                     free-keys.py check; conflicts identify the owner and reject
#                     the change (validation is skipped if free-keys.py is absent)
#   Width           → read and validate a number, then write panel.conf
#                     (blank = restore the default)
#
# Every change immediately writes the corresponding conf file and calls
# gen-config-layer.sh to regenerate generated.yml (gracefully skipped if the
# script is unavailable). lazygit 0.63+ hot-reloads all configuration files
# when the terminal regains focus, so changes take effect when the user returns
# to the lazygit pane without a restart.
#
# Configuration files (all under $HERDR_PLUGIN_CONFIG_DIR and shell-sourceable):
#   ai-backend.conf  AI_BACKEND / AI_<BACKEND>_MODEL / AI_CUSTOM_CMD
#   keys.conf        KEY_COMMIT / KEY_ZOOM / KEY_SETTINGS (missing = plugin
#                    default; stores only the three plugin verb keys; edit
#                    lazygit-user.yml to remap built-in keys)
#   panel.conf       SIDEBAR_COLS / EXPAND_COLS / COMMIT_COLS / SETTINGS_COLS
#                    / LAYOUT_MODE
#
# Test hooks: HERDR_LAZYGIT_GEN_SH / HERDR_LAZYGIT_FREE_KEYS can override the
# gen-config-layer.sh / free-keys.py paths (for self-tests; normally unset).
#
# Hidden subcommand: settings-fzf.sh preview <menu-item> — used by fzf's
# --preview callback into this script.
#
# bash 3.2 compatible (macOS default); complex parsing uses python3 with no
# third-party dependencies other than fzf.
set -euo pipefail

# ---------------------------------------------------------------------------
# Dependency check: if fzf is missing, print installation instructions and exit
# ---------------------------------------------------------------------------
if ! command -v fzf >/dev/null 2>&1; then
  cat >&2 <<'EOF'
settings-fzf.sh: fzf is required for the settings menu.

Install it with either command:
  brew install fzf
  bash "<plugin-directory>/scripts/ensure-fzf.sh"
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# Constants and paths
# ---------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SELF="$script_dir/settings-fzf.sh"
AI_SH="$script_dir/ai-commit-msg.sh"
GEN_SH="${HERDR_LAZYGIT_GEN_SH:-$script_dir/gen-config-layer.sh}"
FREE_KEYS_PY="${HERDR_LAZYGIT_FREE_KEYS:-$script_dir/free-keys.py}"

# Default keys for the plugin's three verbs. These must match def_commit,
# def_zoom, and def_settings in gen-config-layer.sh (the generated layer's
# source of truth); the values here are used only for display and comparison.
DEF_KEY_COMMIT='C'
DEF_KEY_ZOOM='U'
DEF_KEY_SETTINGS=';'

CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
AI_CONF="$CONFIG_DIR/ai-backend.conf"
KEYS_CONF="$CONFIG_DIR/keys.conf"
PANEL_CONF="$CONFIG_DIR/panel.conf"

KEYS_CONF_HEADER='# keys.conf — keys for the three herdr-lazygit plugin verbs (written by settings, read by gen-config-layer.sh).
# Stores only plugin verb keys; edit lazygit-user.yml to remap built-in lazygit keys.'
PANEL_CONF_HEADER='# panel.conf — herdr-lazygit pane geometry and layout state. Written by settings and layout scripts.'

MSG=""        # Result of the previous action, shown in the main-menu header
GEN_NOTE=""   # Result note from regen, appended to MSG

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

# Load all conf files (set defaults before sourcing; model defaults must match
# ai-commit-msg.sh).
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

# Resolve AI_BACKEND=auto using ai-commit-msg.sh's detection order.
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

# Write the header comment when creating a conf file for the first time.
seed_conf() {
  # $1=file $2=header comment
  [ -f "$1" ] && return 0
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$2" > "$1"
}

# Update one KEY=VALUE in a conf file while preserving other lines. Values are
# safely escaped and written in single quotes (equivalent to write_conf_var in
# ai-commit-msg.sh, but with the file path passed as an argument).
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

# Delete a KEY from a conf file (= restore its default).
conf_del() {
  local file="$1" key="$2" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/herdr-lazygit.conf.XXXXXX")"
  grep -v "^${key}=" "$file" > "$tmp" || true
  mv "$tmp" "$file"
}

# Rebuild generated.yml through the generation layer. If the script is absent,
# skip gracefully and explain the result in GEN_NOTE.
regen() {
  if [ -f "$GEN_SH" ]; then
    if bash "$GEN_SH" >/dev/null 2>&1; then
      GEN_NOTE="regenerated generated.yml"
    else
      GEN_NOTE="gen-config-layer.sh failed (conf was written; rerun it manually to diagnose)"
    fi
  else
    GEN_NOTE="generation script unavailable; skipped regeneration (conf was written)"
  fi
}

pause() {
  printf '\nPress any key to return to the menu...'
  IFS= read -rsn1 _ || true
  printf '\n'
}

menu_items() {
  cat <<'EOF'
AI Backend
AI Model
AI Prompt
Keybinding: Commit
Keybinding: Expand
Keybinding: Settings
Sidebar Width
Expanded Width
AI Commit Pane Width
EOF
}

# ---------------------------------------------------------------------------
# preview subcommand: "current value + help" beside/below the main menu
# (fzf --preview callback)
# ---------------------------------------------------------------------------
cmd_preview() {
  load_confs
  local item="${1:-}" b m pf
  case "$item" in
    "AI Backend")
      b="$(resolved_backend)"
      printf 'Current: %s' "$AI_BACKEND"
      [ "$AI_BACKEND" = "auto" ] && printf ' (resolved to %s)' "${b:-no available backend}"
      printf '\n\n'
      "$AI_SH" backends 2>/dev/null | awk -F'\t' '{printf "  %-10s %s\n", $1, $2}'
      printf '\nAbout: The AI CLI used to generate commit messages. auto checks\nclaude > codex > opencode > gemini in order; custom requires\nAI_CUSTOM_CMD in ai-backend.conf.\n'
      ;;
    "AI Model")
      b="$(resolved_backend)"
      case "$b" in
        claude)   m="$AI_CLAUDE_MODEL" ;;
        codex)    m="$AI_CODEX_MODEL" ;;
        opencode) m="$AI_OPENCODE_MODEL" ;;
        gemini)   m="$AI_GEMINI_MODEL" ;;
        *)        m="" ;;
      esac
      printf 'Current backend: %s\n' "${b:-(no available backend)}"
      printf 'Current model: %s\n\n' "${m:-(use CLI default)}"
      printf 'About: Commit messages are a small task, so defaults favor cheap, fast models.\nChoose from the list or enter a model ID; custom does not support model selection.\n'
      ;;
    "AI Prompt")
      pf="$CONFIG_DIR/prompt.txt"
      if [ -s "$pf" ]; then
        printf 'File: %s\n──────\n' "$pf"
        head -8 "$pf"
        printf '\nAbout: Edit the commit-message prompt with $EDITOR. Saving takes effect immediately.\n'
      else
        printf 'Not customized yet (using the built-in prompt).\n\nAbout: Press Enter to open it in $EDITOR; the built-in prompt seeds the file the first time.\n'
      fi
      ;;
    "Keybinding: Commit")
      printf 'Current: %s\n\n' "${KEY_COMMIT:-${DEF_KEY_COMMIT}(plugin default)}"
      printf 'About: Starts the full AI commit-message flow in the files panel.\nThe default C shadows lazygit\x27s infrequently used "commit using git editor" action.\nfree-keys.py validates changes and rejects conflicts with built-in keys.\n'
      ;;
    "Keybinding: Expand")
      printf 'Current: %s\n\n' "${KEY_ZOOM:-${DEF_KEY_ZOOM}(plugin default)}"
      printf 'About: Globally toggles lazygit between sidebar and expanded layouts.\nfree-keys.py validates changes and rejects conflicts with built-in keys.\n'
      ;;
    "Keybinding: Settings")
      printf 'Current: %s\n\n' "${KEY_SETTINGS:-${DEF_KEY_SETTINGS}(plugin default)}"
      printf 'About: Global key that opens this settings page.\nfree-keys.py validates changes and rejects conflicts with built-in keys.\n'
      ;;
    "Sidebar Width")
      if [ -n "$SIDEBAR_COLS" ]; then
        printf 'Current: %s columns\n\n' "$SIDEBAR_COLS"
      else
        printf 'Current: 42 columns (default)\n\n'
      fi
      printf 'About: Width of the lazygit sidebar pane (SIDEBAR_COLS in panel.conf).\nThis width is restored when a supporting pane closes or U collapses lazygit.\n'
      ;;
    "Expanded Width")
      if [ -n "$EXPAND_COLS" ]; then
        printf 'Current: %s columns\n\n' "$EXPAND_COLS"
      else
        printf 'Current: 110 columns (default)\n\n'
      fi
      printf 'About: Target width after pressing Expand (EXPAND_COLS in panel.conf).\nThe actual width is capped at the total tab width minus 20 columns.\n'
      ;;
    "AI Commit Pane Width")
      if [ -n "$COMMIT_COLS" ]; then
        printf 'Current: %s columns\n\n' "$COMMIT_COLS"
      else
        printf 'Current: 70 columns (default)\n\n'
      fi
      printf 'About: Width of the AI commit generation and editing pane (COMMIT_COLS in panel.conf).\n'
      ;;
    *)
      printf '(no preview)\n'
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Flow: AI backend (fzf list populated by ai-commit-msg.sh backends)
# ---------------------------------------------------------------------------
flow_backend() {
  local line name out rc
  line="$("$AI_SH" backends 2>/dev/null | fzf \
      --layout=reverse --no-multi --cycle --tabstop=12 \
      --prompt='AI Backend > ' \
      --header='Enter/double-click = select · Esc = back' \
      --bind 'double-click:accept')" && rc=0 || rc=$?
  [ "$rc" -ne 0 ] && { MSG="Cancelled"; return 0; }
  name="$(printf '%s' "$line" | cut -f1)"
  [ -n "$name" ] || { MSG="Cancelled"; return 0; }
  if out="$("$AI_SH" set-backend "$name" 2>&1)"; then
    regen
    MSG="$out · $GEN_NOTE"
  else
    printf '%s\n' "$out"
    pause
    MSG="Failed to switch backend (see message above)"
  fi
}

# ---------------------------------------------------------------------------
# Flow: AI model (fzf list + manual model-ID entry through --print-query)
# ---------------------------------------------------------------------------
flow_model() {
  local out rc query sel value setout
  out="$("$AI_SH" models 2>/dev/null | fzf \
      --layout=reverse --no-multi --print-query \
      --prompt='AI Model > ' \
      --header='Enter = select; type an unlisted ID and press Enter · Esc = back' \
      --bind 'double-click:accept')" && rc=0 || rc=$?
  # rc=1 means "no match but query present" (--print-query still emits the
  # query line); only rc>=2 means cancellation/error.
  if [ "$rc" -ge 2 ]; then MSG="Cancelled"; return 0; fi
  query="$(printf '%s\n' "$out" | sed -n 1p)"
  sel="$(printf '%s\n' "$out" | sed -n 2p)"
  value="${sel:-$query}"
  [ -n "$value" ] || { MSG="Cancelled"; return 0; }
  if setout="$("$AI_SH" set-model "$value" 2>&1)"; then
    regen
    MSG="$setout · $GEN_NOTE"
  else
    printf '%s\n' "$setout"
    pause
    MSG="Failed to set model (see message above)"
  fi
}

# ---------------------------------------------------------------------------
# Flow: AI Prompt (open the prompt file in $EDITOR)
# ---------------------------------------------------------------------------
flow_prompt() {
  local pf
  pf="$("$AI_SH" prompt-file)"
  # EDITOR may contain arguments (such as "code -w"); leave it unquoted by
  # convention so the shell splits those arguments.
  # shellcheck disable=SC2086
  ${EDITOR:-vi} "$pf" || true
  regen
  MSG="Prompt saved: $pf · $GEN_NOTE"
}

# ---------------------------------------------------------------------------
# Flow: change a keybinding (capture one key with read -rsn1, then validate
# conflicts with free-keys.py check).
# Usage: flow_key <keys.conf variable> <default key> <display name>
#        <contexts for free-keys validation...>
# ---------------------------------------------------------------------------
flow_key() {
  local var="$1" def="$2" label="$3"; shift 3
  local cur key notation out stty_saved
  load_confs
  cur="$(eval "printf '%s' \"\$$var\"")"
  cur="${cur:-$def}"
  clear
  printf 'Change [Keybinding: %s]  (current: %s)\n\n' "$label" "$cur"
  printf 'Press a new key — letters, numbers, symbols, and Ctrl combinations (written as <c-x>) are supported.\n'
  printf 'Esc = cancel. Plugin keys must not shadow common lazygit built-ins; conflicts are rejected.\n\n'
  # Disable flow control so Ctrl-S / Ctrl-Q can be read, then restore terminal
  # settings afterward.
  stty_saved="$(stty -g 2>/dev/null || true)"
  stty -ixon 2>/dev/null || true
  IFS= read -rsn1 key || key=$'\x1b'
  [ -n "$stty_saved" ] && stty "$stty_saved" 2>/dev/null || true
  if [ "$key" = $'\x1b' ]; then
    # Esc itself, or a multibyte escape sequence such as an arrow key: drain
    # the remaining bytes and cancel.
    while IFS= read -rsn1 -t 1 _; do :; done
    MSG="Cancelled"
    return 0
  fi
  if [ -z "$key" ]; then
    MSG="Enter cannot be assigned to a plugin action; cancelled"
    return 0
  fi
  # Convert one byte to lazygit key notation: printable characters stay as-is,
  # while Ctrl combinations become <c-x>. Reject Space, DEL, and other values
  # (Space is lazygit's stage key).
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
    MSG="Unsupported key; cancelled"
    return 0
  fi
  # If the new key matches the current key, accept it without running check.
  # This is part of free-keys.py's documented contract; otherwise accepted
  # exceptions such as default C would be rejected by their own occupancy
  # record and could never be restored.
  if [ "$notation" = "$cur" ]; then
    MSG="[Keybinding: $label] already uses $notation; no change"
    return 0
  fi
  # Conflict validation: free-keys.py check KEY context... (nonzero means a
  # conflict or unavailable key).
  local check_note=""
  if [ -f "$FREE_KEYS_PY" ]; then
    if out="$(python3 "$FREE_KEYS_PY" check "$notation" "$@" 2>&1)"; then
      :
    else
      printf 'Key %s conflicts with a built-in lazygit binding and was rejected:\n%s\n' "$notation" "$out"
      pause
      MSG="[Keybinding: $label] rejected: $notation is already in use"
      return 0
    fi
  else
    check_note=" (free-keys.py unavailable; conflicts were not checked)"
  fi
  seed_conf "$KEYS_CONF" "$KEYS_CONF_HEADER"
  conf_set "$KEYS_CONF" "$var" "$notation"
  regen
  MSG="[Keybinding: $label] set to $notation$check_note · $GEN_NOTE"
}

# ---------------------------------------------------------------------------
# Flow: width (read and validate a number, then write panel.conf; blank deletes
# the setting and restores the default).
# Usage: flow_width <panel.conf variable> <display name> <current description>
#        [minimum]
# ---------------------------------------------------------------------------
flow_width() {
  local var="$1" label="$2" cur="$3" min="${4:-20}" val
  clear
  printf 'Change [%s]  (current: %s)\n\n' "$label" "$cur"
  printf 'Enter a new column count (digits only, %s–500; blank = restore default), then press Enter:\n> ' "$min"
  IFS= read -r val || { MSG="Cancelled"; return 0; }
  if [ -z "$val" ]; then
    conf_del "$PANEL_CONF" "$var"
    regen
    MSG="[$label] restored to default · $GEN_NOTE"
    return 0
  fi
  case "$val" in
    *[!0-9]*) MSG="[$label] invalid input (digits only); no change"; return 0 ;;
  esac
  if [ "$val" -lt "$min" ] || [ "$val" -gt 500 ]; then
    MSG="[$label] $val is outside the allowed range ($min–500); no change"
    return 0
  fi
  seed_conf "$PANEL_CONF" "$PANEL_CONF_HEADER"
  conf_set "$PANEL_CONF" "$var" "$val"
  regen
  MSG="[$label] set to $val columns · $GEN_NOTE"
}

# ---------------------------------------------------------------------------
# Main-menu loop
# ---------------------------------------------------------------------------
main_menu() {
  local header item
  while true; do
    header='Changes apply automatically when you return to the lazygit pane (hot reload)
Enter/double-click = edit · Esc/q = exit'
    if [ -n "$MSG" ]; then
      header="$header
✔ $MSG"
    fi
    item="$(menu_items | fzf \
        --layout=reverse --no-multi --cycle \
        --prompt='lazygit Settings > ' \
        --header="$header" \
        --preview="bash $(printf %q "$SELF") preview {}" \
        --preview-window='down,45%,wrap' \
        --bind 'double-click:accept' \
        --bind 'q:abort')" || return 0
    MSG=""
    case "$item" in
      "AI Backend")       flow_backend ;;
      "AI Model")         flow_model ;;
      "AI Prompt")     flow_prompt ;;
      "Keybinding: Commit")   flow_key KEY_COMMIT "$DEF_KEY_COMMIT" "Commit" files ;;
      "Keybinding: Expand")   flow_key KEY_ZOOM "$DEF_KEY_ZOOM" "Expand" global ;;
      "Keybinding: Settings") flow_key KEY_SETTINGS "$DEF_KEY_SETTINGS" "Settings" global ;;
      "Sidebar Width")
        load_confs
        flow_width SIDEBAR_COLS "Sidebar Width" "${SIDEBAR_COLS:-42 (default)}"
        ;;
      "Expanded Width")
        load_confs
        flow_width EXPAND_COLS "Expanded Width" "${EXPAND_COLS:-110 (default)}" 80
        ;;
      "AI Commit Pane Width")
        load_confs
        flow_width COMMIT_COLS "AI Commit Pane Width" "${COMMIT_COLS:-70 (default)}" 40
        ;;
      "") return 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-menu}" in
  preview) cmd_preview "${2:-}" ;;
  menu)    main_menu ;;
  *)
    echo "Usage: settings-fzf.sh [preview <menu-item>]" >&2
    exit 1
    ;;
esac
