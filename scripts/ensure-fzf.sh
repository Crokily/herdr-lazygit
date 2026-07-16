#!/bin/sh
# [[build]] step: make sure `fzf` is available (UI for Settings and the AI
# commit pane). Called by the [[build]] entry in herdr-plugin.toml as
# ["/bin/sh", "scripts/ensure-fzf.sh"] (the manifest entry is appended through
# builder-keymap coordination), so keep this POSIX sh-compatible (no bashisms).
#   - fzf is on PATH  -> skip
#   - Homebrew exists -> brew install fzf
#   - neither exists  -> print installation instructions and fail the build
set -eu

if command -v fzf >/dev/null 2>&1; then
  echo "fzf found: $(command -v fzf)"
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  echo "fzf not found; installing with Homebrew..."
  brew install fzf
  echo "fzf installed: $(command -v fzf)"
  exit 0
fi

cat >&2 <<'EOF'
error: fzf is not installed and Homebrew is not available.

Install fzf manually, then re-run the plugin install:
  - macOS:          install Homebrew (https://brew.sh), then: brew install fzf
  - Debian/Ubuntu:  apt install fzf
  - Arch:           pacman -S fzf
  - Fedora:         dnf install fzf
  - Any platform:   download a release binary from
                    https://github.com/junegunn/fzf/releases
                    and place it on your PATH
EOF
exit 1
