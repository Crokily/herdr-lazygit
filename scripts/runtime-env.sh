#!/usr/bin/env bash
# Resolve the plugin-private runtime installed by scripts/install-runtime.sh.
# Source this from runtime entrypoints; it deliberately does not modify PATH, so
# the plugin always invokes the tested binaries by absolute path.
#
# Escape hatch: users who prefer their own binaries can set RUNTIME_LAZYGIT_BIN
# and/or RUNTIME_FZF_BIN in $HERDR_PLUGIN_CONFIG_DIR/panel.conf (absolute
# paths). A pre-exported HERDR_LAZYGIT_BIN / HERDR_LAZYGIT_FZF_BIN wins over
# panel.conf — that is also how the resolved paths propagate consistently to
# child scripts. Overridden binaries are unsupported territory: the generated
# config and key analysis are tested only against the pinned versions, so
# herdr_lazygit_version_notice warns when the versions differ.

_herdr_lazygit_runtime_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HERDR_LAZYGIT_RUNTIME_SCRIPT_DIR="$_herdr_lazygit_runtime_script_dir"
HERDR_LAZYGIT_RUNTIME_ROOT="${HERDR_LAZYGIT_ROOT:-${HERDR_PLUGIN_ROOT:-$(cd "$_herdr_lazygit_runtime_script_dir/.." && pwd)}}"
HERDR_LAZYGIT_CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-lazygit}"
_herdr_lazygit_versions="$(
  ( . "$_herdr_lazygit_runtime_script_dir/runtime-versions.sh" >/dev/null 2>&1 \
      && printf '%s %s' "${LAZYGIT_VERSION:-}" "${FZF_VERSION:-}" ) 2>/dev/null
)"
read -r HERDR_LAZYGIT_PINNED_VERSION HERDR_LAZYGIT_PINNED_FZF_VERSION <<< "$_herdr_lazygit_versions"

# panel.conf overrides, sourced in a subshell so a broken file cannot kill the
# caller (mirrors gen-config-layer.sh's pattern).
_herdr_lazygit_conf_lazygit=""
_herdr_lazygit_conf_fzf=""
if [ -f "$HERDR_LAZYGIT_CONFIG_DIR/panel.conf" ]; then
  eval "$(
    ( . "$HERDR_LAZYGIT_CONFIG_DIR/panel.conf" >/dev/null 2>&1 || exit 0
      printf '_herdr_lazygit_conf_lazygit=%q\n_herdr_lazygit_conf_fzf=%q\n' \
        "${RUNTIME_LAZYGIT_BIN:-}" "${RUNTIME_FZF_BIN:-}" ) 2>/dev/null
  )"
fi

HERDR_LAZYGIT_BIN="${HERDR_LAZYGIT_BIN:-${_herdr_lazygit_conf_lazygit:-$HERDR_LAZYGIT_RUNTIME_ROOT/bin/lazygit}}"
HERDR_LAZYGIT_FZF_BIN="${HERDR_LAZYGIT_FZF_BIN:-${_herdr_lazygit_conf_fzf:-$HERDR_LAZYGIT_RUNTIME_ROOT/bin/fzf}}"
export HERDR_LAZYGIT_RUNTIME_ROOT HERDR_LAZYGIT_CONFIG_DIR HERDR_LAZYGIT_BIN HERDR_LAZYGIT_FZF_BIN

herdr_lazygit_require_runtime() {
  local tool="${1:-}" path private
  case "$tool" in
    lazygit) path="$HERDR_LAZYGIT_BIN" ;;
    fzf)     path="$HERDR_LAZYGIT_FZF_BIN" ;;
    *)
      printf 'runtime-env.sh: unknown runtime tool: %s\n' "$tool" >&2
      return 1
      ;;
  esac
  private="$HERDR_LAZYGIT_RUNTIME_ROOT/bin/$tool"

  case "$path" in
    /*) ;;
    *)
      printf 'herdr-lazygit: the configured %s override must be an absolute path: %s\n' "$tool" "$path" >&2
      return 1
      ;;
  esac

  if [ ! -x "$path" ]; then
    if [ "$path" != "$private" ]; then
      cat >&2 <<EOF
herdr-lazygit: the configured $tool override is missing or not executable: $path

Fix the RUNTIME_$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')_BIN entry in
$HERDR_LAZYGIT_CONFIG_DIR/panel.conf, or remove it to use the private runtime.
EOF
      return 1
    fi
    cat >&2 <<EOF
herdr-lazygit: private $tool runtime is missing: $path

GitHub installs create it automatically. For a locally linked checkout, run:
  /bin/sh "$HERDR_LAZYGIT_RUNTIME_ROOT/scripts/install-runtime.sh"
EOF
    return 1
  fi
}

# When a runtime binary is overridden, warn (stderr only, never fatal) if its
# version differs from the pinned one the plugin is tested against.
herdr_lazygit_version_notice() {
  local tool="${1:-lazygit}" actual path pinned
  case "$tool" in
    lazygit) path="$HERDR_LAZYGIT_BIN"; pinned="$HERDR_LAZYGIT_PINNED_VERSION" ;;
    fzf) path="$HERDR_LAZYGIT_FZF_BIN"; pinned="$HERDR_LAZYGIT_PINNED_FZF_VERSION" ;;
    *) return 1 ;;
  esac
  [ "$path" != "$HERDR_LAZYGIT_RUNTIME_ROOT/bin/$tool" ] || return 0
  [ -n "$pinned" ] || return 0
  actual="$(python3 - "$HERDR_LAZYGIT_RUNTIME_SCRIPT_DIR" "$tool" "$path" <<'PY'
import re, sys
sys.path.insert(0, sys.argv[1])
from process_helper import run_command
try:
    result = run_command([sys.argv[3], '--version'])
    result.check_returncode()
    if sys.argv[2] == 'lazygit':
        match = re.search(r'version=([^,\s]+)', result.stdout)
        print(match.group(1) if match else '')
    else:
        print(result.stdout.split()[0])
except Exception:
    pass
PY
  )" || true
  if [ "$actual" != "$pinned" ]; then
    printf 'herdr-lazygit: overridden %s is %s but the plugin is tested against %s; configuration and interaction may misbehave.\n' \
      "$tool" "${actual:-an unknown version}" "$pinned" >&2
  fi
}

unset _herdr_lazygit_runtime_script_dir _herdr_lazygit_versions _herdr_lazygit_conf_lazygit _herdr_lazygit_conf_fzf
