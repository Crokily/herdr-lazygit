#!/usr/bin/env bash
# Resolve the plugin-private runtime installed by scripts/install-runtime.sh.
# Source this from runtime entrypoints; it deliberately does not modify PATH, so
# the plugin always invokes the tested binaries by absolute path.

_herdr_lazygit_runtime_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HERDR_LAZYGIT_RUNTIME_ROOT="${HERDR_LAZYGIT_ROOT:-${HERDR_PLUGIN_ROOT:-$(cd "$_herdr_lazygit_runtime_script_dir/.." && pwd)}}"
HERDR_LAZYGIT_BIN="$HERDR_LAZYGIT_RUNTIME_ROOT/bin/lazygit"
HERDR_LAZYGIT_FZF_BIN="$HERDR_LAZYGIT_RUNTIME_ROOT/bin/fzf"
export HERDR_LAZYGIT_RUNTIME_ROOT HERDR_LAZYGIT_BIN HERDR_LAZYGIT_FZF_BIN

herdr_lazygit_require_runtime() {
  local tool="${1:-}" path
  case "$tool" in
    lazygit) path="$HERDR_LAZYGIT_BIN" ;;
    fzf)     path="$HERDR_LAZYGIT_FZF_BIN" ;;
    *)
      printf 'runtime-env.sh: unknown runtime tool: %s\n' "$tool" >&2
      return 1
      ;;
  esac

  if [ ! -x "$path" ]; then
    cat >&2 <<EOF
herdr-lazygit: private $tool runtime is missing: $path

GitHub installs create it automatically. For a locally linked checkout, run:
  /bin/sh "$HERDR_LAZYGIT_RUNTIME_ROOT/scripts/install-runtime.sh"
EOF
    return 1
  fi
}

unset _herdr_lazygit_runtime_script_dir
