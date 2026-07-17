#!/usr/bin/env bash
# Hermetic staged-diff sampling tests for scripts/ai-commit-msg.sh.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/herdr-lazygit-ai-diff-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

init_repo() {
  local repo=$1
  git init -q "$repo"
  (
    cd "$repo"
    GIT_AUTHOR_NAME='Test User' \
    GIT_AUTHOR_EMAIL='test@example.com' \
    GIT_COMMITTER_NAME='Test User' \
    GIT_COMMITTER_EMAIL='test@example.com' \
      git commit --allow-empty -m init >/dev/null
  )
}

# ---------------------------------------------------------------------------
# Large staged diffs must always include a complete file overview, preserve the
# small source hunks, and avoid letting a lockfile consume the whole budget.
# ---------------------------------------------------------------------------
sample_repo="$tmp/sample-repo"
init_repo "$sample_repo"
mkdir -p "$sample_repo/src"

python3 - "$sample_repo/package-lock.json" <<'PY'
import json
import sys

deps = {}
for idx in range(700):
    deps[f"pkg{idx:04d}"] = {
        "version": "1.0.%d" % (idx % 10),
        "resolved": "https://example.invalid/pkgs/%04d/%s" % (idx, "x" * 40),
        "integrity": "sha512-" + ("a" * 88),
    }

payload = {
    "name": "sample-lockfile",
    "lockfileVersion": 3,
    "requires": True,
    "packages": {},
    "dependencies": deps,
}

with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

cat > "$sample_repo/src/alpha.js" <<'EOF'
export function alpha() {
  return "alpha";
}
EOF

cat > "$sample_repo/src/beta.js" <<'EOF'
export function beta() {
  return "beta";
}
EOF

git -C "$sample_repo" add package-lock.json src/alpha.js src/beta.js
(
  cd "$sample_repo"
  HERDR_LAZYGIT_TEST_PRINT_AI_INPUT=1 \
    bash "$repo_root/scripts/ai-commit-msg.sh" candidates > "$tmp/sampled.txt"
)

grep -Fxq 'STAGED DIFF OVERVIEW' "$tmp/sampled.txt"
grep -Fq 'package-lock.json' "$tmp/sampled.txt"
grep -Fq 'src/alpha.js' "$tmp/sampled.txt"
grep -Fq 'src/beta.js' "$tmp/sampled.txt"
grep -Fq 'diff --git a/src/alpha.js b/src/alpha.js' "$tmp/sampled.txt"
grep -Fq 'diff --git a/src/beta.js b/src/beta.js' "$tmp/sampled.txt"
grep -Fq 'return "alpha";' "$tmp/sampled.txt"
grep -Fq 'return "beta";' "$tmp/sampled.txt"
if grep -Fq 'diff --git a/package-lock.json b/package-lock.json' "$tmp/sampled.txt"; then
  echo 'lockfile patch body should not consume the sampled diff budget' >&2
  cat "$tmp/sampled.txt" >&2
  exit 1
fi
grep -Eq '^COVERAGE: sampled [0-9]+/[0-9]+ files, [0-9]+/[0-9]+ hunks; input is a sample of the staged diff$' "$tmp/sampled.txt"

# ---------------------------------------------------------------------------
# Small staged diffs should go through unchanged.
# ---------------------------------------------------------------------------
fast_repo="$tmp/fast-repo"
init_repo "$fast_repo"
mkdir -p "$fast_repo/src"
cat > "$fast_repo/src/small.sh" <<'EOF'
#!/bin/sh
printf '%s\n' hello
EOF

git -C "$fast_repo" add src/small.sh
git -C "$fast_repo" diff --cached > "$tmp/expected-fast.txt"
(
  cd "$fast_repo"
  HERDR_LAZYGIT_TEST_PRINT_AI_INPUT=1 \
    bash "$repo_root/scripts/ai-commit-msg.sh" candidates > "$tmp/actual-fast.txt"
)

if ! cmp -s "$tmp/expected-fast.txt" "$tmp/actual-fast.txt"; then
  echo 'small staged diffs should be passed to the AI unchanged' >&2
  diff -u "$tmp/expected-fast.txt" "$tmp/actual-fast.txt" >&2 || true
  exit 1
fi

printf 'ai diff sampling tests passed\n'
