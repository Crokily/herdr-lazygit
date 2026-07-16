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
if [ -n "\${FAKE_NOEXEC_PREFIX:-}" ]; then
  case "\$0" in
    "\$FAKE_NOEXEC_PREFIX"/*) exit 126 ;;
  esac
fi
printf '%s test-runtime\\n' '$tool'
EOF_TOOL
chmod +x "$destination/$tool"
EOF

cat > "$fake_bin/uname" <<'EOF'
#!/bin/sh
set -eu
case "${1:-}" in
  -s) printf '%s\n' "$FAKE_UNAME_S" ;;
  -m) printf '%s\n' "$FAKE_UNAME_M" ;;
  *) exit 2 ;;
esac
EOF

cat > "$fake_bin/mv" <<'EOF'
#!/bin/sh
set -eu
if [ "${FAKE_MV_FAIL_FZF_PUBLISH:-0}" = 1 ] && [ "$#" -eq 2 ]; then
  case "$1:$2" in
    */.runtime-stage.*/fzf:*/bin/fzf)
      : > "$FAKE_MV_FAILURE_MARKER"
      exit 1
      ;;
  esac
fi
if [ "${FAKE_MV_FAIL_LAZYGIT_RESTORE:-0}" = 1 ] && [ "$#" -eq 3 ] && [ "$1" = -f ]; then
  case "$2:$3" in
    */.runtime-backup.*/lazygit:*/bin/lazygit)
      : > "$FAKE_MV_RESTORE_FAILURE_MARKER"
      exit 1
      ;;
  esac
fi
exec /bin/mv "$@"
EOF

chmod +x "$fake_bin/curl" "$fake_bin/sha256sum" "$fake_bin/tar" "$fake_bin/uname" "$fake_bin/mv"

make_checkout() {
  local root=$1
  mkdir -p "$root/scripts"
  cp "$repo_root/scripts/install-runtime.sh" "$root/scripts/"
  cp "$repo_root/scripts/runtime-versions.sh" "$root/scripts/"
}

run_target() {
  local os=$1 arch=$2 expected_lazygit=$3 expected_fzf=$4 name root out log
  name="${os}-${arch}"
  root="$tmp/$name/checkout"
  out="$root/bin"
  log="$tmp/$name/downloads.log"
  make_checkout "$root"
  mkdir -p "$(dirname "$log")"
  : > "$log"

  PATH="$fake_bin:$PATH" \
  FAKE_DOWNLOAD_LOG="$log" \
  FAKE_UNAME_S="$os" \
  FAKE_UNAME_M="$arch" \
  HERDR_LAZYGIT_LAZYGIT_BASE_URL='https://fixtures.invalid/lazygit' \
  HERDR_LAZYGIT_FZF_BASE_URL='https://fixtures.invalid/fzf' \
    /bin/sh "$root/scripts/install-runtime.sh" >/dev/null

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

# A real build must always keep its runtime inside the managed checkout, even
# when a shell happens to export test or legacy output-directory overrides.
production_root="$tmp/production-build"
escaped_root="$tmp/escaped-runtime"
production_log="$tmp/production-build.log"
make_checkout "$production_root"
: > "$production_log"
PATH="$fake_bin:$PATH" \
FAKE_DOWNLOAD_LOG="$production_log" \
FAKE_UNAME_S=Linux \
FAKE_UNAME_M=x86_64 \
HERDR_LAZYGIT_TEST_MODE=1 \
HERDR_LAZYGIT_RUNTIME_BIN_DIR="$escaped_root/legacy" \
HERDR_LAZYGIT_TEST_RUNTIME_BIN_DIR="$escaped_root/test" \
HERDR_LAZYGIT_LAZYGIT_BASE_URL='https://fixtures.invalid/lazygit' \
HERDR_LAZYGIT_FZF_BASE_URL='https://fixtures.invalid/fzf' \
  /bin/sh "$production_root/scripts/install-runtime.sh" >/dev/null
[ -x "$production_root/bin/lazygit" ]
[ -x "$production_root/bin/fzf" ]
[ ! -e "$escaped_root/legacy/lazygit" ]
[ ! -e "$escaped_root/test/lazygit" ]

# Smoke tests must run from the destination filesystem rather than TMPDIR. The
# fake runtime returns EACCES-like status 126 only when executed below the
# synthetic noexec prefix; extraction there remains valid.
noexec_root="$tmp/noexec-build"
noexec_tmp="$tmp/noexec-tmp"
noexec_log="$tmp/noexec-build.log"
make_checkout "$noexec_root"
mkdir -p "$noexec_tmp"
: > "$noexec_log"
PATH="$fake_bin:$PATH" \
TMPDIR="$noexec_tmp" \
FAKE_DOWNLOAD_LOG="$noexec_log" \
FAKE_NOEXEC_PREFIX="$noexec_tmp" \
FAKE_UNAME_S=Linux \
FAKE_UNAME_M=x86_64 \
HERDR_LAZYGIT_LAZYGIT_BASE_URL='https://fixtures.invalid/lazygit' \
HERDR_LAZYGIT_FZF_BASE_URL='https://fixtures.invalid/fzf' \
  /bin/sh "$noexec_root/scripts/install-runtime.sh" >/dev/null
[ -x "$noexec_root/bin/lazygit" ]
[ -x "$noexec_root/bin/fzf" ]

# Unsupported targets fail before installing anything.
unsupported_root="$tmp/unsupported/checkout"
make_checkout "$unsupported_root"
if PATH="$fake_bin:$PATH" \
   FAKE_DOWNLOAD_LOG="$tmp/unsupported.log" \
   FAKE_UNAME_S=Linux \
   FAKE_UNAME_M=riscv64 \
     /bin/sh "$unsupported_root/scripts/install-runtime.sh" >/dev/null 2>&1; then
  echo "expected unsupported architecture to fail" >&2
  exit 1
fi
[ ! -e "$unsupported_root/bin/lazygit" ]

# A checksum mismatch aborts before either staged tool reaches the destination.
mismatch_root="$tmp/mismatch/checkout"
mismatch_log="$tmp/mismatch.log"
make_checkout "$mismatch_root"
: > "$mismatch_log"
if PATH="$fake_bin:$PATH" \
   FAKE_DOWNLOAD_LOG="$mismatch_log" \
   FAKE_SHA_MISMATCH=1 \
   FAKE_UNAME_S=Linux \
   FAKE_UNAME_M=x86_64 \
     /bin/sh "$mismatch_root/scripts/install-runtime.sh" >/dev/null 2>&1; then
  echo "expected checksum mismatch to fail" >&2
  exit 1
fi
[ ! -e "$mismatch_root/bin/lazygit" ]
[ ! -e "$mismatch_root/bin/fzf" ]

# A failed second publication must restore the complete previous pair and
# remove all transaction directories.
rollback_root="$tmp/rollback/checkout"
rollback_log="$tmp/rollback.log"
rollback_marker="$tmp/rollback-publication-reached"
make_checkout "$rollback_root"
mkdir -p "$rollback_root/bin"
cat > "$rollback_root/bin/lazygit" <<'EOF'
#!/bin/sh
printf '%s\n' old-lazygit
EOF
cat > "$rollback_root/bin/fzf" <<'EOF'
#!/bin/sh
printf '%s\n' old-fzf
EOF
chmod +x "$rollback_root/bin/lazygit" "$rollback_root/bin/fzf"
: > "$rollback_log"
if PATH="$fake_bin:$PATH" \
   FAKE_DOWNLOAD_LOG="$rollback_log" \
   FAKE_MV_FAIL_FZF_PUBLISH=1 \
   FAKE_MV_FAILURE_MARKER="$rollback_marker" \
   FAKE_UNAME_S=Linux \
   FAKE_UNAME_M=x86_64 \
   HERDR_LAZYGIT_LAZYGIT_BASE_URL='https://fixtures.invalid/lazygit' \
   HERDR_LAZYGIT_FZF_BASE_URL='https://fixtures.invalid/fzf' \
     /bin/sh "$rollback_root/scripts/install-runtime.sh" >/dev/null 2>&1; then
  echo "expected second runtime publication to fail" >&2
  exit 1
fi
[ -f "$rollback_marker" ]
[ "$("$rollback_root/bin/lazygit")" = old-lazygit ]
[ "$("$rollback_root/bin/fzf")" = old-fzf ]
[ -z "$(find "$rollback_root/bin" -mindepth 1 -maxdepth 1 -name '.*' -print)" ]

# If restoring the old pair also fails, retain the rollback directory instead
# of deleting the only remaining recovery copy.
restore_failure_root="$tmp/restore-failure/checkout"
restore_failure_log="$tmp/restore-failure.log"
restore_failure_error="$tmp/restore-failure.err"
restore_failure_publish_marker="$tmp/restore-failure-publication-reached"
restore_failure_marker="$tmp/restore-failure-reached"
make_checkout "$restore_failure_root"
mkdir -p "$restore_failure_root/bin"
cp "$rollback_root/bin/lazygit" "$restore_failure_root/bin/lazygit"
cp "$rollback_root/bin/fzf" "$restore_failure_root/bin/fzf"
: > "$restore_failure_log"
if PATH="$fake_bin:$PATH" \
   FAKE_DOWNLOAD_LOG="$restore_failure_log" \
   FAKE_MV_FAIL_FZF_PUBLISH=1 \
   FAKE_MV_FAILURE_MARKER="$restore_failure_publish_marker" \
   FAKE_MV_FAIL_LAZYGIT_RESTORE=1 \
   FAKE_MV_RESTORE_FAILURE_MARKER="$restore_failure_marker" \
   FAKE_UNAME_S=Linux \
   FAKE_UNAME_M=x86_64 \
   HERDR_LAZYGIT_LAZYGIT_BASE_URL='https://fixtures.invalid/lazygit' \
   HERDR_LAZYGIT_FZF_BASE_URL='https://fixtures.invalid/fzf' \
     /bin/sh "$restore_failure_root/scripts/install-runtime.sh" \
       >/dev/null 2>"$restore_failure_error"; then
  echo "expected publication and rollback restoration to fail" >&2
  exit 1
fi
[ -f "$restore_failure_publish_marker" ]
[ -f "$restore_failure_marker" ]
retained_backup="$(find "$restore_failure_root/bin" -mindepth 1 -maxdepth 1 \
  -type d -name '.runtime-backup.*' -print -quit)"
[ -n "$retained_backup" ]
[ "$("$retained_backup/lazygit")" = old-lazygit ]
[ "$("$restore_failure_root/bin/fzf")" = old-fzf ]
reported_backup="$(sed -n \
  's/^herdr-lazygit: rollback incomplete; recovery binaries retained in //p' \
  "$restore_failure_error")"
[ -n "$reported_backup" ]
[ "$(cd "$reported_backup" && pwd -P)" = "$(cd "$retained_backup" && pwd -P)" ]

# Non-file destinations must fail instead of accepting mv's directory
# semantics and reporting an unusable installation as successful.
directory_root="$tmp/directory-destination/checkout"
directory_log="$tmp/directory-destination.log"
directory_error="$tmp/directory-destination.err"
make_checkout "$directory_root"
mkdir -p "$directory_root/bin/lazygit"
if PATH="$fake_bin:$PATH" \
   FAKE_DOWNLOAD_LOG="$directory_log" \
   FAKE_UNAME_S=Linux \
   FAKE_UNAME_M=x86_64 \
     /bin/sh "$directory_root/scripts/install-runtime.sh" >/dev/null 2>"$directory_error"; then
  echo "expected a directory runtime destination to fail" >&2
  exit 1
fi
grep -qF 'runtime destination is not a regular file:' "$directory_error"
[ ! -e "$directory_log" ]
[ -d "$directory_root/bin/lazygit" ]
[ ! -e "$directory_root/bin/fzf" ]

printf 'install-runtime tests passed\n'
