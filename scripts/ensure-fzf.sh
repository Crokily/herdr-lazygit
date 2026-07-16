#!/bin/sh
# [[build]] step:make sure `fzf` is available(设置页与 AI commit pane 的 UI)。
# 由 herdr-plugin.toml 的 [[build]] 以 ["/bin/sh", "scripts/ensure-fzf.sh"] 调用
# (manifest 条目由 builder-keymap 协调追加),所以保持 POSIX sh(no bashisms)。
#   - fzf 已在 PATH   -> 跳过
#   - 有 Homebrew     -> brew install fzf
#   - 都没有          -> 打印安装指引并让 build 失败
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
