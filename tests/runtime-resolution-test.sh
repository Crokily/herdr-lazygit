#!/usr/bin/env bash
# Hermetic tests for runtime resolution and config layering: the panel.conf
# binary overrides and version notice in scripts/runtime-env.sh, the user-config
# inheritance (layer 0) and visible-failure behavior in scripts/run-lazygit.sh,
# and the launcher runtime precheck in scripts/open-lazygit.sh. A stub lazygit
# binary keeps this fast and network-free.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/herdr-lazygit-resolution-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Stub lazygit: reports a configurable user config dir and version, and echoes
# the LG_CONFIG_FILE it was launched with (exit code via FAKE_EXIT).
stub="$tmp/stub-lazygit"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --print-config-dir) printf '%s\n' "${FAKE_USER_DIR:-}" ;;
  --version) printf 'commit=x, build date=x, build source=binaryRelease, version=%s, os=darwin, arch=arm64, git version=2.50.1 (Apple Git-155)\n' "${FAKE_VERSION:-0.63.0}" ;;
  *) printf 'STUB_LG_CONFIG_FILE=%s\n' "${LG_CONFIG_FILE:-}"; exit "${FAKE_EXIT:-0}" ;;
esac
EOF
chmod 0755 "$stub"

user_dir="$tmp/user-lazygit-config"
mkdir -p "$user_dir"
printf 'gui:\n' > "$user_dir/config.yml"

run_pane() {
  # run_pane <config_dir> [extra env...] — runs the pane entrypoint with the
  # stub binary and a throwaway HOME, stdin not a tty.
  local conf="$1"; shift
  mkdir -p "$conf"
  env HOME="$tmp/home" FAKE_USER_DIR="$user_dir" HERDR_LAZYGIT_BIN="$stub" \
    HERDR_PLUGIN_ROOT="$repo_root" HERDR_PLUGIN_CONFIG_DIR="$conf" "$@" \
    bash "$repo_root/scripts/run-lazygit.sh" </dev/null
}

# --- Layer 0 is inherited by default and merges under the plugin layers ------
out="$(run_pane "$tmp/conf-default" 2>/dev/null)"
case "$out" in
  "STUB_LG_CONFIG_FILE=$user_dir/config.yml,$repo_root/lazygit-config.yml,"*) ;;
  *)
    echo "expected the user config as the first layer, got: $out" >&2
    exit 1
    ;;
esac

# --- INHERIT_USER_CONFIG=0 drops layer 0 --------------------------------------
mkdir -p "$tmp/conf-optout"
printf "INHERIT_USER_CONFIG=0\n" > "$tmp/conf-optout/panel.conf"
out="$(run_pane "$tmp/conf-optout" 2>/dev/null)"
case "$out" in
  "STUB_LG_CONFIG_FILE=$repo_root/lazygit-config.yml,"*) ;;
  *)
    echo "expected no inherited layer with INHERIT_USER_CONFIG=0, got: $out" >&2
    exit 1
    ;;
esac

# --- No personal config file: layer 0 is simply absent ------------------------
out="$(run_pane "$tmp/conf-nouser" FAKE_USER_DIR="$tmp/does-not-exist" 2>/dev/null)"
case "$out" in
  "STUB_LG_CONFIG_FILE=$repo_root/lazygit-config.yml,"*) ;;
  *)
    echo "expected no inherited layer without a personal config, got: $out" >&2
    exit 1
    ;;
esac

# --- A failing lazygit keeps its exit code and prints actionable guidance -----
status=0
err="$(run_pane "$tmp/conf-fail" FAKE_EXIT=3 2>&1 >/dev/null)" || status=$?
if [ "$status" -ne 3 ]; then
  echo "expected the pane to preserve lazygit's exit code 3, got $status" >&2
  exit 1
fi
case "$err" in
  *"lazygit exited with status 3"*INHERIT_USER_CONFIG=0*) ;;
  *)
    echo "expected a visible failure message naming INHERIT_USER_CONFIG, got: $err" >&2
    exit 1
    ;;
esac

# --- Launcher precheck: missing private runtime fails the action loudly -------
status=0
err="$(env HOME="$tmp/home" HERDR_PLUGIN_ROOT="$tmp/no-runtime-root" \
  HERDR_PLUGIN_CONFIG_DIR="$tmp/conf-pre" HERDR_LAZYGIT_TEST_DECISION=1 \
  HERDR_BIN_PATH=/usr/bin/false bash "$repo_root/scripts/open-lazygit.sh" 2>&1 >/dev/null)" \
  || status=$?
if [ "$status" -ne 1 ]; then
  echo "expected the launcher precheck to exit 1, got $status" >&2
  exit 1
fi
case "$err" in
  *"private lazygit runtime is missing"*) ;;
  *)
    echo "expected a missing-runtime message from the precheck, got: $err" >&2
    exit 1
    ;;
esac

# --- Launcher precheck: a broken panel.conf override names the culprit --------
mkdir -p "$tmp/conf-broken"
printf "RUNTIME_LAZYGIT_BIN='/nonexistent/lazygit'\n" > "$tmp/conf-broken/panel.conf"
status=0
err="$(env HOME="$tmp/home" HERDR_PLUGIN_ROOT="$repo_root" \
  HERDR_PLUGIN_CONFIG_DIR="$tmp/conf-broken" HERDR_LAZYGIT_TEST_DECISION=1 \
  HERDR_BIN_PATH=/usr/bin/false bash "$repo_root/scripts/open-lazygit.sh" 2>&1 >/dev/null)" \
  || status=$?
if [ "$status" -ne 1 ] ; then
  echo "expected the broken override to exit 1, got $status" >&2
  exit 1
fi
case "$err" in
  *RUNTIME_LAZYGIT_BIN*) ;;
  *)
    echo "expected the error to name RUNTIME_LAZYGIT_BIN, got: $err" >&2
    exit 1
    ;;
esac

# --- panel.conf override is honored and a version mismatch warns --------------
mkdir -p "$tmp/conf-override"
printf "RUNTIME_LAZYGIT_BIN='%s'\n" "$stub" > "$tmp/conf-override/panel.conf"
out_err="$tmp/override.err"
out="$(env HOME="$tmp/home" FAKE_USER_DIR="$user_dir" FAKE_VERSION=0.99.0 \
  HERDR_PLUGIN_ROOT="$repo_root" HERDR_PLUGIN_CONFIG_DIR="$tmp/conf-override" \
  HERDR_LAZYGIT_TEST_DECISION=1 HERDR_BIN_PATH=/usr/bin/false \
  bash "$repo_root/scripts/open-lazygit.sh" 2>"$out_err")"
case "$out" in
  OPEN*) ;;
  *)
    echo "expected the launcher to proceed with a valid override, got: $out" >&2
    exit 1
    ;;
esac
if ! grep -q "0.99.0" "$out_err" || ! grep -q "0.63.0" "$out_err"; then
  echo "expected a version-mismatch notice naming both versions:" >&2
  cat "$out_err" >&2
  exit 1
fi

echo "runtime resolution tests passed"
