#!/bin/sh
# herdr [[build]] step: install the plugin-private lazygit and fzf runtime.
#
# Herdr runs build commands in the managed checkout before registering it. We
# download pinned upstream release archives for the current OS/architecture,
# verify repository-pinned SHA-256 digests, and place the binaries under bin/.
# Nothing is installed globally and no package manager or sudo is invoked.
#
# Supported targets:
#   macOS: x86_64, arm64
#   Linux: x86_64, arm64/aarch64
#
# Build commands do not receive HERDR_PLUGIN_ROOT, so resolve the checkout from
# this script. Keep this file POSIX sh-compatible: Herdr invokes it with /bin/sh.
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
plugin_root=$(CDPATH= cd "$script_dir/.." && pwd)
# shellcheck disable=SC1091
. "$script_dir/runtime-versions.sh"

bin_dir="$plugin_root/bin"
lazygit_base_url="${HERDR_LAZYGIT_LAZYGIT_BASE_URL:-https://github.com/jesseduffield/lazygit/releases/download}"
fzf_base_url="${HERDR_LAZYGIT_FZF_BASE_URL:-https://github.com/junegunn/fzf/releases/download}"

have() { command -v "$1" >/dev/null 2>&1; }
fatal() {
  printf 'herdr-lazygit: %s\n' "$*" >&2
  exit 1
}

for command_name in bash git python3 tar; do
  have "$command_name" || fatal "$command_name is required on PATH"
done
python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 7))' \
  || fatal "python3 3.7 or newer is required"
if ! have curl && ! have wget; then
  fatal "curl or wget is required to download the private runtime"
fi
if ! have sha256sum && ! have shasum; then
  fatal "sha256sum or shasum is required to verify runtime downloads"
fi

os_raw=$(uname -s 2>/dev/null || printf unknown)
arch_raw=$(uname -m 2>/dev/null || printf unknown)
case "$os_raw" in
  Darwin) os=darwin ;;
  Linux)  os=linux ;;
  *) fatal "unsupported operating system: $os_raw (supported: macOS, Linux)" ;;
esac
case "$arch_raw" in
  x86_64|amd64)
    lazygit_arch=x86_64
    fzf_arch=amd64
    ;;
  arm64|aarch64)
    lazygit_arch=arm64
    fzf_arch=arm64
    ;;
  *) fatal "unsupported architecture: $arch_raw (supported: x86_64, arm64/aarch64)" ;;
esac

lazygit_asset="lazygit_${LAZYGIT_VERSION}_${os}_${lazygit_arch}.tar.gz"
fzf_asset="fzf-${FZF_VERSION}-${os}_${fzf_arch}.tar.gz"

# Digests copied from the upstream v0.63.0 and v0.74.0 checksum files. Keeping
# them in the repository means a compromised or corrupted archive cannot be
# trusted merely because a checksum sidecar came from the same download host.
expected_checksum() {
  case "$1" in
    lazygit:darwin:arm64)  printf '%s\n' '60e6bf29a1501a57a9d078538aa576a1b4db45779db2e3dd6931a7207f560a9c' ;;
    lazygit:darwin:x86_64) printf '%s\n' '304b1bf7f7bbb5a5d59e34145bce63d42733cd828e4fe41428ced9ee4dbfe942' ;;
    lazygit:linux:arm64)   printf '%s\n' 'aac147abf5ce43afe6ae8bcb14b0d479111975a189302d7a99386deca70d57f7' ;;
    lazygit:linux:x86_64)  printf '%s\n' 'cf5cfa3e116d7775f3600a51ec1d9ce7ba554a08b9566c7c2da83cb0023efabf' ;;
    fzf:darwin:arm64)      printf '%s\n' 'da60e8980e4239a0fc5f1fcfe873f243dfda93a6a13b696b00e1dc8584a77a87' ;;
    fzf:darwin:amd64)      printf '%s\n' 'e2c470f058ac18615f54c0bebe0fd2956f2aa8e306a11621783a00aaa386eedd' ;;
    fzf:linux:arm64)       printf '%s\n' 'bd9e6165ebdb702215d42368cbb95b8dd70a4e77ee97925adac8c31660e30ef7' ;;
    fzf:linux:amd64)       printf '%s\n' 'cf919f05b7581b4c744d764eaa704665d61dd6d3ca785f0df2351281dff60cda' ;;
    *) return 1 ;;
  esac
}

fetch() {
  url=$1
  destination=$2
  if have curl; then
    curl -fsSL --retry 3 --retry-delay 1 -o "$destination" "$url"
  else
    wget -q -O "$destination" "$url"
  fi
}

sha256_of() {
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/herdr-lazygit-runtime.XXXXXX") \
  || fatal "could not create a temporary directory"
stage=""
backup=""
publish_complete=0
had_lazygit=0
had_fzf=0
published_lazygit=0
published_fzf=0
cleanup() {
  status=$?
  rollback_failed=0
  trap - EXIT HUP INT TERM

  if [ "$publish_complete" -ne 1 ] && [ -n "$backup" ]; then
    if [ "$published_lazygit" -eq 1 ]; then
      if ! rm -f "$bin_dir/lazygit"; then
        printf 'herdr-lazygit: failed to remove the partial lazygit update\n' >&2
        rollback_failed=1
      fi
    fi
    if [ "$published_fzf" -eq 1 ]; then
      if ! rm -f "$bin_dir/fzf"; then
        printf 'herdr-lazygit: failed to remove the partial fzf update\n' >&2
        rollback_failed=1
      fi
    fi
    if [ "$had_lazygit" -eq 1 ] && [ -f "$backup/lazygit" ]; then
      if ! mv -f "$backup/lazygit" "$bin_dir/lazygit"; then
        printf 'herdr-lazygit: failed to restore the previous lazygit binary\n' >&2
        rollback_failed=1
      fi
    fi
    if [ "$had_fzf" -eq 1 ] && [ -f "$backup/fzf" ]; then
      if ! mv -f "$backup/fzf" "$bin_dir/fzf"; then
        printf 'herdr-lazygit: failed to restore the previous fzf binary\n' >&2
        rollback_failed=1
      fi
    fi
  fi

  [ -z "$stage" ] || rm -rf "$stage" || :
  if [ -n "$backup" ]; then
    if [ "$publish_complete" -eq 1 ] || [ "$rollback_failed" -eq 0 ]; then
      rm -rf "$backup" || :
    else
      printf 'herdr-lazygit: rollback incomplete; recovery binaries retained in %s\n' \
        "$backup" >&2
    fi
  fi
  rm -rf "$tmpdir" || :
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Keep executable staging on the destination filesystem. Hardened Linux hosts
# commonly mount /tmp with noexec; downloads and extraction can stay there, but
# smoke-testing the runtime must happen where the installed binaries will run.
mkdir -p "$bin_dir" || fatal "could not create runtime directory: $bin_dir"
for destination in "$bin_dir/lazygit" "$bin_dir/fzf"; do
  if [ -L "$destination" ]; then
    fatal "runtime destination is not a regular file: $destination"
  elif [ -e "$destination" ]; then
    [ -f "$destination" ] \
      || fatal "runtime destination is not a regular file: $destination"
  fi
done
stage=$(mktemp -d "$bin_dir/.runtime-stage.XXXXXX") \
  || fatal "could not create runtime staging under $bin_dir"

install_archive() {
  tool=$1
  asset=$2
  url=$3
  expected=$4
  archive="$tmpdir/$asset"
  extract_dir="$tmpdir/extract-$tool"

  printf 'herdr-lazygit: downloading %s\n' "$asset"
  fetch "$url" "$archive" || fatal "failed to download $url"

  actual=$(sha256_of "$archive") || fatal "failed to hash $asset"
  [ "$actual" = "$expected" ] \
    || fatal "checksum mismatch for $asset (expected $expected, got $actual)"

  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir" \
    || fatal "failed to extract $asset"
  [ -f "$extract_dir/$tool" ] \
    || fatal "$asset did not contain the expected $tool binary"
  cp "$extract_dir/$tool" "$stage/$tool"
  chmod 0755 "$stage/$tool"
}

lazygit_checksum=$(expected_checksum "lazygit:$os:$lazygit_arch") \
  || fatal "no lazygit checksum for $os/$lazygit_arch"
fzf_checksum=$(expected_checksum "fzf:$os:$fzf_arch") \
  || fatal "no fzf checksum for $os/$fzf_arch"

install_archive \
  lazygit "$lazygit_asset" \
  "$lazygit_base_url/v${LAZYGIT_VERSION}/$lazygit_asset" \
  "$lazygit_checksum"
install_archive \
  fzf "$fzf_asset" \
  "$fzf_base_url/v${FZF_VERSION}/$fzf_asset" \
  "$fzf_checksum"

"$stage/lazygit" --version >/dev/null 2>&1 \
  || fatal "the downloaded lazygit binary cannot run on $os_raw/$arch_raw"
"$stage/fzf" --version >/dev/null 2>&1 \
  || fatal "the downloaded fzf binary cannot run on $os_raw/$arch_raw"

# Replace both tools only after both downloads have verified, extracted, and
# executed successfully from the destination filesystem. Preserve the prior
# pair until publication completes so a failed second rename can roll back the
# first instead of leaving a mixed runtime.
backup=$(mktemp -d "$bin_dir/.runtime-backup.XXXXXX") \
  || fatal "could not create runtime rollback directory under $bin_dir"
if [ -f "$bin_dir/lazygit" ]; then
  had_lazygit=1
  mv "$bin_dir/lazygit" "$backup/lazygit"
fi
if [ -f "$bin_dir/fzf" ]; then
  had_fzf=1
  mv "$bin_dir/fzf" "$backup/fzf"
fi

published_lazygit=1
mv "$stage/lazygit" "$bin_dir/lazygit"
published_fzf=1
mv "$stage/fzf" "$bin_dir/fzf"
[ -f "$bin_dir/lazygit" ] && [ -x "$bin_dir/lazygit" ] \
  || fatal "failed to publish the lazygit runtime binary"
[ -f "$bin_dir/fzf" ] && [ -x "$bin_dir/fzf" ] \
  || fatal "failed to publish the fzf runtime binary"
publish_complete=1

printf 'herdr-lazygit: installed private runtime in %s\n' "$bin_dir"
printf '  lazygit %s (%s/%s)\n' "$LAZYGIT_VERSION" "$os" "$lazygit_arch"
printf '  fzf %s (%s/%s)\n' "$FZF_VERSION" "$os" "$fzf_arch"
