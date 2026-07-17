#!/usr/bin/env bash
# gen-config-layer.sh — generate the intermediate generated.yml layer in the
# layered configuration model.
#
# Three configuration layers (see DESIGN.md):
#   lazygit-config.yml (bundled with the plugin)
#     → $HERDR_PLUGIN_CONFIG_DIR/generated.yml (generated here; do not edit)
#       → $HERDR_PLUGIN_CONFIG_DIR/layout-*.yml (per-pane layout layer written
#         by run-lazygit.sh / toggle-expand.sh)
#         → $HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml (user-authored, always
#           last and therefore always wins)
#
# Input: $HERDR_PLUGIN_CONFIG_DIR/keys.conf (written by Settings and
# shell-sourceable). Missing files/values use defaults:
#   KEY_COMMIT=C   KEY_ZOOM=U   KEY_SETTINGS=';'
# (U and ';' come from scripts/free-keys.py's free-key analysis of built-in
# lazygit 0.63.0 bindings: Z is occupied by universal.redo, <c-s> by
# universal.filteringMenu, and O by branches.viewPullRequestOptions; U and ';'
# are unused in every panel.)
#
# Output: generated.yml containing
#   - customCommands: KEY_COMMIT (opens AI commit pane), KEY_ZOOM (global,
#     toggles layout), and KEY_SETTINGS (global, calls open-settings-pane.sh)
#   - keybinding: conditional <disabled> compatibility for old handwritten
#     KEY_SETTINGS configurations. KEY_ZOOM / KEY_SETTINGS are now global;
#     Settings rejects any panel conflict through free-keys.py check. The
#     defaults U / ';' are unused everywhere, so this section is normally absent.
#
# Idempotent and millisecond-scale: skip when generated.yml is newer than
# keys.conf, this script, and free-keys.py. Writes use tmp+mv so lazygit's hot
# reload never reads a partial file.
#
# bash 3.2 compatible (macOS default).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Use the same pinned lazygit binary as the pane when checking built-in key
# conflicts, including when this generator is run directly during development.
# shellcheck disable=SC1091
. "$script_dir/runtime-env.sh"
# shellcheck disable=SC1091
. "$script_dir/runtime-versions.sh"

config_dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
mkdir -p "$config_dir"
keys_conf="$config_dir/keys.conf"
out="$config_dir/generated.yml"

# Default keys for the plugin's three verbs (DEF_KEY_* in settings-fzf.sh must
# remain synchronized with these values).
def_commit='C' ; def_zoom='U' ; def_settings=';'

self="${BASH_SOURCE[0]:-$0}"

# --- Read keys.conf (use defaults for missing values) -----------------------
# Source it in a subshell so a broken file (syntax error) does not kill this
# script and instead falls back to the default keys.
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

# --- Validate key syntax: warn and restore defaults for invalid values; never
#     write invalid values to generated.yml ----------------------------------
# Valid lazygit keys are a single character or a named <...> key (such as
# <c-s>, <enter>, or <tab>). A bare multi-character string such as abc makes
# lazygit fail at startup with "Unrecognized key" (the validation-error screen
# prevents the entire lazygit pane from opening), so reject it before generation
# and restore the default (see DESIGN.md's graceful-degradation rule: invalid
# value = default + warning).
valid_key() {
  case "$1" in
    '<'*'>') [ ${#1} -ge 3 ] ;;   # named key <...>
    *)       [ ${#1} -eq 1 ] ;;   # exactly one character
  esac
}
warn_bad_key() {
  printf 'gen-config-layer.sh: invalid key %s=%s; restored default %s (valid keys: one character or a named <...> key)\n' \
    "$1" "$2" "$3" >&2
}
valid_key "$k_commit"   || { warn_bad_key KEY_COMMIT   "$k_commit"   "$def_commit";   k_commit="$def_commit"; }
valid_key "$k_zoom"     || { warn_bad_key KEY_ZOOM     "$k_zoom"     "$def_zoom";     k_zoom="$def_zoom"; }
valid_key "$k_settings" || { warn_bad_key KEY_SETTINGS "$k_settings" "$def_settings"; k_settings="$def_settings"; }

# --- Cache: do not regenerate when generated.yml already reflects the
#     validated keys ---------------------------------------------------------
# Compare a content marker rather than mtime: bash 3.2's -nt has one-second
# precision, so two rapid key changes within the same second can share an mtime,
# miss the update, and keep that stale state across restarts (where relaunch
# generation also skips). Comparing the "# keys: ..." header marker is
# independent of write time and eliminates this problem. It also covers deleting
# keys.conf to restore defaults (the marker then becomes the default-key line).
# The lazygit version participates in the marker because built-in key conflicts
# can change between releases. Script/runtime mtimes also invalidate a persisted
# generated layer after a plugin reinstall or local runtime rebuild.
marker="# keys: $k_commit $k_zoom $k_settings | lazygit: $LAZYGIT_VERSION"
if [ -f "$out" ] \
   && grep -qxF "$marker" "$out" 2>/dev/null \
   && [ ! "$self" -nt "$out" ] \
   && [ ! "$script_dir/free-keys.py" -nt "$out" ] \
   && [ ! "$script_dir/runtime-versions.sh" -nt "$out" ] \
   && [ ! "$HERDR_LAZYGIT_BIN" -nt "$out" ]; then
  exit 0
fi

# Escape YAML single quotes ('' represents one ').
yaml_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

qc="$(yaml_quote "$k_commit")"
qz="$(yaml_quote "$k_zoom")"
qs="$(yaml_quote "$k_settings")"

# --- Panel-level KEY_SETTINGS conflicts → <disabled> ------------------------
# free-keys.py check outputs "<ctx>\t<section>.<action>". Ignore the universal
# section (global custom already overrides global built-in), disabling only
# same-key built-ins in panel sections. If free-keys.py is unavailable (exit 2),
# skip silently; the file must still be generated.
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
        printf "\n# KEY_SETTINGS(%s) conflicts with these panel built-ins; disabled as needed\n", KEY
        printf "# (to restore them, choose an unused key in Settings)\n"
        printf "keybinding:\n"
        for (i = 1; i <= cnt; i++) printf "  %s:\n%s", order[i], acts[order[i]]
      }' KEY="$k_settings")"
  fi
fi

# --- Generate ----------------------------------------------------------------
tmp="$out.tmp.$$"
{
  cat <<'EOF'
# generated.yml — machine-generated by gen-config-layer.sh; do not edit
EOF
  # Marker line: record generation inputs so the cache detects deleted key
  # overrides and lazygit runtime upgrades.
  printf '# keys: %s %s %s | lazygit: %s\n' \
    "$k_commit" "$k_zoom" "$k_settings" "$LAZYGIT_VERSION"
  cat <<'EOF'
#
# Change keys through Settings (press the Settings key in lazygit), or edit
# keys.conf and reopen lazygit. Override any setting here in lazygit-user.yml,
# which loads after this file and always wins.
EOF
  cat <<'EOF'

customCommands:
EOF

  # -- KEY_COMMIT: open responsive, editable AI commit pane (files panel) -----
  printf '  - key: %s\n' "$qc"
  cat <<'EOF'
    context: 'files'
    description: 'Open AI commit pane'
    output: 'none'
    command: >-
      sh -c 'bash "$HERDR_LAZYGIT_ROOT/scripts/open-ai-commit-pane.sh"'
EOF

  # -- KEY_ZOOM: globally toggle sidebar / expanded layout -------------------
  printf '\n  - key: %s\n' "$qz"
  cat <<'EOF'
    context: 'global'
    description: 'Expand/collapse lazygit'
    output: 'none'
    command: >-
      sh -c 'bash "$HERDR_LAZYGIT_ROOT/scripts/toggle-expand.sh"'
EOF

  # -- KEY_SETTINGS: plugin settings pane (global) ---------------------------
  printf '\n  - key: %s\n' "$qs"
  cat <<'EOF'
    context: 'global'
    description: 'Open herdr-lazygit settings pane'
    command: >-
      sh -c 'bash "$HERDR_LAZYGIT_ROOT/scripts/open-settings-pane.sh"'
EOF

  [ -n "$kb_section" ] && printf '%s\n' "$kb_section"
} > "$tmp"
mv "$tmp" "$out"
