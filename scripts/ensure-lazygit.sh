#!/bin/sh
# [[build]] step: make sure the `lazygit` binary is available.
# Runs at plugin install time via ["/bin/sh", "scripts/ensure-lazygit.sh"],
# so this stays POSIX sh (no bashisms).
#   - lazygit already on PATH -> nothing to do
#   - Homebrew available      -> brew install lazygit
#   - neither                 -> print install instructions and fail the build
set -eu

if command -v lazygit >/dev/null 2>&1; then
  echo "lazygit found: $(command -v lazygit)"
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  echo "lazygit not found; installing with Homebrew..."
  brew install lazygit
  echo "lazygit installed: $(command -v lazygit)"
  exit 0
fi

cat >&2 <<'EOF'
error: lazygit is not installed and Homebrew is not available.

Install lazygit manually, then re-run the plugin install:
  - macOS:          install Homebrew (https://brew.sh), then: brew install lazygit
  - Debian/Ubuntu:  see https://github.com/jesseduffield/lazygit#ubuntu
  - Arch:           pacman -S lazygit
  - Fedora:         dnf copr enable atim/lazygit -y && dnf install lazygit
  - Any platform:   download a release binary from
                    https://github.com/jesseduffield/lazygit/releases
                    and place it on your PATH
EOF
exit 1
