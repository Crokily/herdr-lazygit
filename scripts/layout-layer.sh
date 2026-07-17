#!/usr/bin/env bash
# layout-layer.sh — helpers for the per-pane lazygit layout-state layer.
#
# Each lazygit pane gets its own YAML file (layout-<pid>-<epoch>.yml) that sits
# between generated.yml and lazygit-user.yml in LG_CONFIG_FILE. The file stores
# only the pane-local layout mode (sidebar|expanded) plus the gui settings that
# depend on that mode.
#
# bash 3.2 compatible (macOS default).

herdr_lazygit_normalize_layout_mode() {
  case "${1:-}" in
    sidebar|expanded) printf '%s\n' "$1" ;;
    *)                printf 'sidebar\n' ;;
  esac
}

herdr_lazygit_read_layout_mode() {
  local file="${1:-}" mode
  mode=""
  if [ -n "$file" ] && [ -f "$file" ]; then
    mode="$(sed -n 's/^# layout: //p' "$file" | sed -n '1p')"
  fi
  herdr_lazygit_normalize_layout_mode "$mode"
}

herdr_lazygit_write_layout_layer() {
  local out="${1:-}" mode="${2:-sidebar}" tmp side_panel_width
  [ -n "$out" ] || {
    printf 'layout-layer.sh: output path is required\n' >&2
    return 1
  }

  mode="$(herdr_lazygit_normalize_layout_mode "$mode")"
  case "$mode" in
    expanded) side_panel_width="0.3333" ;;
    *)        side_panel_width="0.99" ;;
  esac

  mkdir -p "$(dirname "$out")"
  tmp="$out.tmp.$$"
  {
    cat <<'EOF'
# per-pane lazygit layout layer — machine-generated, do not edit
EOF
    printf '# layout: %s\n' "$mode"
    printf 'gui:\n  sidePanelWidth: %s\n' "$side_panel_width"
    cat <<'EOF'
  expandFocusedSidePanel: true
  portraitMode: never
EOF
  } > "$tmp"
  mv "$tmp" "$out"
}

herdr_lazygit_cleanup_stale_layout_layers() {
  local config_dir="${1:-}" path base pid
  [ -d "$config_dir" ] || return 0

  for path in "$config_dir"/layout-*-*.yml; do
    [ -e "$path" ] || continue
    base="${path##*/}"
    pid="${base#layout-}"
    pid="${pid%%-*}"
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    kill -0 "$pid" 2>/dev/null || rm -f "$path"
  done
}
