#!/usr/bin/env bash
# Drive the actual settings menu with a deterministic fzf, preserving user data.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/herdr-settings-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config"
cat > "$tmp/fzf" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'lazygit Settings > '*)
    if [ -f "$MENU_DONE" ]; then exit 130; fi
    touch "$MENU_DONE"
    cat >/dev/null
    printf '%s\n' "$MENU_ITEM"
    ;;
  *) cat >/dev/null; printf '%s\n' "$MENU_SELECTION" ;;
esac
EOF
chmod +x "$tmp/fzf"
cat > "$tmp/config/panel.conf" <<'EOF'
# Keep my preferences
INHERIT_USER_CONFIG=0
SIDEBAR_COLS=48
RUNTIME_FZF_BIN='/my custom/fzf'
EOF
printf 'unchanged generated layer\n' > "$tmp/config/generated.yml"
printf 'unchanged current layout\n' > "$tmp/config/layout-live.yml"
for variant in Split Tab; do
  rm -f "$tmp/done"
  env HERDR_PLUGIN_CONFIG_DIR="$tmp/config" HERDR_LAZYGIT_FZF_BIN="$tmp/fzf" \
    MENU_DONE="$tmp/done" MENU_ITEM="Initial $variant Layout" MENU_SELECTION=expanded \
    bash "$repo_root/scripts/settings-fzf.sh"
done
grep -q "^DEFAULT_MODE_SPLIT='expanded'$" "$tmp/config/panel.conf"
grep -q "^DEFAULT_MODE_TAB='expanded'$" "$tmp/config/panel.conf"
grep -q '^INHERIT_USER_CONFIG=0$' "$tmp/config/panel.conf"
grep -q "^RUNTIME_FZF_BIN='/my custom/fzf'$" "$tmp/config/panel.conf"
grep -q '^unchanged generated layer$' "$tmp/config/generated.yml"
grep -q '^unchanged current layout$' "$tmp/config/layout-live.yml"
rm -f "$tmp/done"
env HERDR_PLUGIN_CONFIG_DIR="$tmp/config" HERDR_LAZYGIT_FZF_BIN="$tmp/fzf" \
  MENU_DONE="$tmp/done" MENU_ITEM='Initial Split Layout' MENU_SELECTION='Default (sidebar)' \
  bash "$repo_root/scripts/settings-fzf.sh"
if grep -q '^DEFAULT_MODE_SPLIT=' "$tmp/config/panel.conf"; then exit 1; fi
preview="$(env HERDR_PLUGIN_CONFIG_DIR="$tmp/config" HERDR_LAZYGIT_FZF_BIN="$tmp/fzf" \
  bash "$repo_root/scripts/settings-fzf.sh" preview 'Initial Split Layout')"
case "$preview" in *'sidebar (default)'*'newly opened panes only'*) ;; *) exit 1 ;; esac
printf 'settings initial-layout tests passed\n'
