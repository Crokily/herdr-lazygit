#!/usr/bin/env bash
# Hermetic platform/checksum tests for scripts/install-runtime.sh. Fake release
# archives keep this fast while exercising all four supported target mappings.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/herdr-lazygit-runtime-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fake_bin="$tmp/fake-bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/curl" <<'EOF'
#!/bin/sh
set -eu
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) out=$2; shift 2 ;;
    --retry|--retry-delay) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
[ -n "$out" ] && [ -n "$url" ]
printf '%s\n' "$url" >> "$FAKE_DOWNLOAD_LOG"
printf '%s\n' "$url" > "$out"
EOF

cat > "$fake_bin/sha256sum" <<'EOF'
#!/bin/sh
set -eu
if [ "${FAKE_SHA_MISMATCH:-0}" = 1 ]; then
  hash=0000000000000000000000000000000000000000000000000000000000000000
else
  case "${1##*/}" in
    lazygit_0.63.0_darwin_arm64.tar.gz)  hash=60e6bf29a1501a57a9d078538aa576a1b4db45779db2e3dd6931a7207f560a9c ;;
    lazygit_0.63.0_darwin_x86_64.tar.gz) hash=304b1bf7f7bbb5a5d59e34145bce63d42733cd828e4fe41428ced9ee4dbfe942 ;;
    lazygit_0.63.0_linux_arm64.tar.gz)   hash=aac147abf5ce43afe6ae8bcb14b0d479111975a189302d7a99386deca70d57f7 ;;
    lazygit_0.63.0_linux_x86_64.tar.gz)  hash=cf5cfa3e116d7775f3600a51ec1d9ce7ba554a08b9566c7c2da83cb0023efabf ;;
    fzf-0.74.0-darwin_amd64.tar.gz)      hash=e2c470f058ac18615f54c0bebe0fd2956f2aa8e306a11621783a00aaa386eedd ;;
    fzf-0.74.0-darwin_arm64.tar.gz)      hash=da60e8980e4239a0fc5f1fcfe873f243dfda93a6a13b696b00e1dc8584a77a87 ;;
    fzf-0.74.0-linux_amd64.tar.gz)       hash=cf919f05b7581b4c744d764eaa704665d61dd6d3ca785f0df2351281dff60cda ;;
    fzf-0.74.0-linux_arm64.tar.gz)       hash=bd9e6165ebdb702215d42368cbb95b8dd70a4e77ee97925adac8c31660e30ef7 ;;
    *) exit 2 ;;
  esac
fi
printf '%s  %s\n' "$hash" "$1"
EOF

cat > "$fake_bin/tar" <<'EOF'
#!/bin/sh
set -eu
archive=""
destination=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -xzf) archive=$2; shift 2 ;;
    -C) destination=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "${archive##*/}" in
  lazygit_*) tool=lazygit ;;
  fzf-*) tool=fzf ;;
  *) exit 2 ;;
esac
cat > "$destination/$tool" <<EOF_TOOL
#!/bin/sh
printf '%s test-runtime\\n' '$tool'
EOF_TOOL
chmod +x "$destination/$tool"
EOF

chmod +x "$fake_bin/curl" "$fake_bin/sha256sum" "$fake_bin/tar"

run_target() {
  local os=$1 arch=$2 expected_lazygit=$3 expected_fzf=$4 name out log
  name="${os}-${arch}"
  out="$tmp/$name/bin"
  log="$tmp/$name/downloads.log"
  mkdir -p "$(dirname "$log")"
  : > "$log"

  PATH="$fake_bin:$PATH" \
  FAKE_DOWNLOAD_LOG="$log" \
  HERDR_LAZYGIT_TEST_OS="$os" \
  HERDR_LAZYGIT_TEST_ARCH="$arch" \
  HERDR_LAZYGIT_RUNTIME_BIN_DIR="$out" \
  HERDR_LAZYGIT_LAZYGIT_BASE_URL='https://fixtures.invalid/lazygit' \
  HERDR_LAZYGIT_FZF_BASE_URL='https://fixtures.invalid/fzf' \
    /bin/sh "$repo_root/scripts/install-runtime.sh" >/dev/null

  [ -x "$out/lazygit" ]
  [ -x "$out/fzf" ]
  "$out/lazygit" | grep -q '^lazygit test-runtime$'
  "$out/fzf" | grep -q '^fzf test-runtime$'
  grep -q "/$expected_lazygit$" "$log"
  grep -q "/$expected_fzf$" "$log"
}

run_target Darwin x86_64 \
  lazygit_0.63.0_darwin_x86_64.tar.gz fzf-0.74.0-darwin_amd64.tar.gz
run_target Darwin arm64 \
  lazygit_0.63.0_darwin_arm64.tar.gz fzf-0.74.0-darwin_arm64.tar.gz
run_target Linux x86_64 \
  lazygit_0.63.0_linux_x86_64.tar.gz fzf-0.74.0-linux_amd64.tar.gz
run_target Linux aarch64 \
  lazygit_0.63.0_linux_arm64.tar.gz fzf-0.74.0-linux_arm64.tar.gz

# Unsupported targets fail before installing anything.
if PATH="$fake_bin:$PATH" \
   FAKE_DOWNLOAD_LOG="$tmp/unsupported.log" \
   HERDR_LAZYGIT_TEST_OS=Linux \
   HERDR_LAZYGIT_TEST_ARCH=riscv64 \
   HERDR_LAZYGIT_RUNTIME_BIN_DIR="$tmp/unsupported/bin" \
     /bin/sh "$repo_root/scripts/install-runtime.sh" >/dev/null 2>&1; then
  echo "expected unsupported architecture to fail" >&2
  exit 1
fi
[ ! -e "$tmp/unsupported/bin/lazygit" ]

# A checksum mismatch aborts before either staged tool reaches the destination.
: > "$tmp/mismatch.log"
if PATH="$fake_bin:$PATH" \
   FAKE_DOWNLOAD_LOG="$tmp/mismatch.log" \
   FAKE_SHA_MISMATCH=1 \
   HERDR_LAZYGIT_TEST_OS=Linux \
   HERDR_LAZYGIT_TEST_ARCH=x86_64 \
   HERDR_LAZYGIT_RUNTIME_BIN_DIR="$tmp/mismatch/bin" \
     /bin/sh "$repo_root/scripts/install-runtime.sh" >/dev/null 2>&1; then
  echo "expected checksum mismatch to fail" >&2
  exit 1
fi
[ ! -e "$tmp/mismatch/bin/lazygit" ]
[ ! -e "$tmp/mismatch/bin/fzf" ]

printf 'install-runtime tests passed\n'
