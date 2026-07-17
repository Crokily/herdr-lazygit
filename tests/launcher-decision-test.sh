#!/usr/bin/env bash
# Hermetic launcher-decision tests for scripts/open-lazygit.sh and
# scripts/open-lazygit-tab.sh. A fake HERDR_BIN_PATH returns canned pane JSON
# and process-info responses, while real temporary git repos/worktrees verify
# same-worktree reuse versus wrong-repo OPEN behavior.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/herdr-lazygit-launcher-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fake_herdr="$tmp/fake-herdr"
cat > "$fake_herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "pane list")
    cat "$FAKE_HERDR_PANES_JSON_FILE"
    ;;
  "pane current")
    cat "$FAKE_HERDR_CURRENT_JSON_FILE"
    ;;
  "pane process-info")
    pane_id=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pane)
          pane_id="${2:-}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [ -n "$pane_id" ]
    cat "$FAKE_HERDR_PROCESS_INFO_DIR/$pane_id.json"
    ;;
  *)
    printf 'unexpected fake herdr command: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_herdr"

git_commit() {
  local repo=$1
  (
    cd "$repo"
    printf '%s\n' init > tracked.txt
    git add tracked.txt
    GIT_AUTHOR_NAME='Test User' \
    GIT_AUTHOR_EMAIL='test@example.com' \
    GIT_COMMITTER_NAME='Test User' \
    GIT_COMMITTER_EMAIL='test@example.com' \
      git commit -m init >/dev/null
  )
}

make_repo() {
  local repo=$1
  git init "$repo" >/dev/null
  git_commit "$repo"
}

write_process_info() {
  local dir=$1 pane_id=$2 proc_name=$3 argv0=$4
  cat > "$dir/$pane_id.json" <<EOF
{"result":{"process_info":{"foreground_processes":[{"name":"$proc_name","argv0":"$argv0"}]}}}
EOF
}

make_context_json() {
  python3 -c 'import json, sys; print(json.dumps({"focused_pane_cwd": sys.argv[1]}))' "$1"
}

run_decision() {
  local script=$1 target_dir=$2 panes_file=$3 current_file=$4 process_dir=$5
  env \
    HERDR_BIN_PATH="$fake_herdr" \
    HERDR_LAZYGIT_BIN=/usr/bin/true \
    HERDR_PLUGIN_ROOT="$repo_root" \
    HERDR_PLUGIN_CONFIG_DIR="$tmp/config" \
    HERDR_LAZYGIT_TEST_DECISION=1 \
    HERDR_PLUGIN_CONTEXT_JSON="$(make_context_json "$target_dir")" \
    FAKE_HERDR_PANES_JSON_FILE="$panes_file" \
    FAKE_HERDR_CURRENT_JSON_FILE="$current_file" \
    FAKE_HERDR_PROCESS_INFO_DIR="$process_dir" \
    bash "$script"
}

assert_decision() {
  local expected=$1 script=$2 target_dir=$3 panes_file=$4 current_file=$5 process_dir=$6
  local out actual
  out="$(run_decision "$script" "$target_dir" "$panes_file" "$current_file" "$process_dir")"
  actual="$(printf '%s\n' "$out" | sed -n '1p')"
  if [ "$actual" != "$expected" ]; then
    printf 'expected %s from %s, got %s\n' "$expected" "$script" "$actual" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}

main_repo="$tmp/main-repo"
other_repo="$tmp/other-repo"
worktree_repo="$tmp/main-repo-worktree"
bare_repo="$tmp/shared-bare.git"
make_repo "$main_repo"
make_repo "$other_repo"
git init --bare "$bare_repo" >/dev/null
mkdir -p "$main_repo/subdir" "$other_repo/subdir"
git -C "$main_repo" worktree add -b worktree-branch "$worktree_repo" >/dev/null
mkdir -p "$worktree_repo/subdir"

nongit_a="$tmp/non-git-a"
nongit_b="$tmp/non-git-b"
stale_dir="$tmp/does-not-exist"
mkdir -p "$nongit_a" "$nongit_b"

process_dir="$tmp/process-info"
mkdir -p "$process_dir" "$tmp/config"
write_process_info "$process_dir" pane-same lazygit lazygit
write_process_info "$process_dir" pane-other lazygit lazygit
write_process_info "$process_dir" pane-worktree lazygit lazygit
write_process_info "$process_dir" pane-path lazygit lazygit
write_process_info "$process_dir" pane-cross lazygit lazygit
write_process_info "$process_dir" pane-tab lazygit lazygit
write_process_info "$process_dir" pane-bare lazygit lazygit
write_process_info "$process_dir" pane-fallback lazygit lazygit

current_file="$tmp/current.json"
cat > "$current_file" <<'EOF'
{"result":{"pane":{"workspace_id":"ws-1","tab_id":"tab-1"}}}
EOF

same_repo_panes="$tmp/panes-same-repo.json"
cat > "$same_repo_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-same","workspace_id":"ws-1","tab_id":"tab-1","label":"Git","focused":false,"cwd":"$other_repo","foreground_cwd":"$main_repo"}]}}
EOF
assert_decision "FOCUS pane-same" \
  "$repo_root/scripts/open-lazygit.sh" "$main_repo/subdir" \
  "$same_repo_panes" "$current_file" "$process_dir"

same_repo_focused_panes="$tmp/panes-same-repo-focused.json"
cat > "$same_repo_focused_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-same","workspace_id":"ws-1","tab_id":"tab-1","label":"Git","focused":true,"cwd":"$other_repo","foreground_cwd":"$main_repo/subdir"}]}}
EOF
assert_decision "CLOSE pane-same" \
  "$repo_root/scripts/open-lazygit.sh" "$main_repo" \
  "$same_repo_focused_panes" "$current_file" "$process_dir"

same_bare_panes="$tmp/panes-same-bare.json"
cat > "$same_bare_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-bare","workspace_id":"ws-1","tab_id":"tab-1","label":"Git","focused":false,"cwd":"$bare_repo"}]}}
EOF
assert_decision "FOCUS pane-bare" \
  "$repo_root/scripts/open-lazygit.sh" "$bare_repo" \
  "$same_bare_panes" "$current_file" "$process_dir"

same_bare_focused_panes="$tmp/panes-same-bare-focused.json"
cat > "$same_bare_focused_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-bare","workspace_id":"ws-1","tab_id":"tab-1","label":"Git","focused":true,"cwd":"$bare_repo"}]}}
EOF
assert_decision "CLOSE pane-bare" \
  "$repo_root/scripts/open-lazygit.sh" "$bare_repo" \
  "$same_bare_focused_panes" "$current_file" "$process_dir"

different_repo_panes="$tmp/panes-different-repo.json"
cat > "$different_repo_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-other","workspace_id":"ws-1","tab_id":"tab-1","label":"Git","focused":false,"cwd":"$other_repo"}]}}
EOF
assert_decision "OPEN" \
  "$repo_root/scripts/open-lazygit.sh" "$main_repo" \
  "$different_repo_panes" "$current_file" "$process_dir"

different_worktree_panes="$tmp/panes-different-worktree.json"
cat > "$different_worktree_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-worktree","workspace_id":"ws-1","tab_id":"tab-1","label":"Git","focused":false,"cwd":"$main_repo"}]}}
EOF
assert_decision "OPEN" \
  "$repo_root/scripts/open-lazygit.sh" "$worktree_repo/subdir" \
  "$different_worktree_panes" "$current_file" "$process_dir"

nongit_same_path_panes="$tmp/panes-nongit-same.json"
cat > "$nongit_same_path_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-path","workspace_id":"ws-1","tab_id":"tab-1","label":"Git","focused":false,"cwd":"$nongit_a"}]}}
EOF
assert_decision "FOCUS pane-path" \
  "$repo_root/scripts/open-lazygit.sh" "$nongit_a" \
  "$nongit_same_path_panes" "$current_file" "$process_dir"

nongit_different_path_panes="$tmp/panes-nongit-different.json"
cat > "$nongit_different_path_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-path","workspace_id":"ws-1","tab_id":"tab-1","label":"Git","focused":false,"cwd":"$nongit_a"}]}}
EOF
assert_decision "OPEN" \
  "$repo_root/scripts/open-lazygit.sh" "$nongit_b" \
  "$nongit_different_path_panes" "$current_file" "$process_dir"

fallback_repo_panes="$tmp/panes-fallback-repo.json"
cat > "$fallback_repo_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-fallback","workspace_id":"ws-1","tab_id":"tab-1","label":"Git","focused":false,"cwd":"$main_repo","foreground_cwd":"$stale_dir"}]}}
EOF
assert_decision "FOCUS pane-fallback" \
  "$repo_root/scripts/open-lazygit.sh" "$main_repo/subdir" \
  "$fallback_repo_panes" "$current_file" "$process_dir"

cross_workspace_panes="$tmp/panes-cross-workspace.json"
cat > "$cross_workspace_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-cross","workspace_id":"ws-2","tab_id":"tab-9","label":"Git","focused":false,"cwd":"$main_repo"}]}}
EOF
assert_decision "OPEN" \
  "$repo_root/scripts/open-lazygit.sh" "$main_repo" \
  "$cross_workspace_panes" "$current_file" "$process_dir"

tab_same_worktree_panes="$tmp/panes-tab-same-worktree.json"
cat > "$tab_same_worktree_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-tab","workspace_id":"ws-1","tab_id":"tab-2","label":"Git","focused":false,"cwd":"$main_repo/subdir"}]}}
EOF
assert_decision "SWITCHTAB tab-2" \
  "$repo_root/scripts/open-lazygit-tab.sh" "$main_repo" \
  "$tab_same_worktree_panes" "$current_file" "$process_dir"

tab_same_bare_panes="$tmp/panes-tab-same-bare.json"
cat > "$tab_same_bare_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-tab","workspace_id":"ws-1","tab_id":"tab-2","label":"Git","focused":false,"cwd":"$bare_repo"}]}}
EOF
assert_decision "SWITCHTAB tab-2" \
  "$repo_root/scripts/open-lazygit-tab.sh" "$bare_repo" \
  "$tab_same_bare_panes" "$current_file" "$process_dir"

tab_different_repo_panes="$tmp/panes-tab-different-repo.json"
cat > "$tab_different_repo_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-tab","workspace_id":"ws-1","tab_id":"tab-2","label":"Git","focused":false,"cwd":"$other_repo"}]}}
EOF
assert_decision "OPEN" \
  "$repo_root/scripts/open-lazygit-tab.sh" "$main_repo" \
  "$tab_different_repo_panes" "$current_file" "$process_dir"

tab_different_worktree_panes="$tmp/panes-tab-different-worktree.json"
cat > "$tab_different_worktree_panes" <<EOF
{"result":{"panes":[{"pane_id":"pane-tab","workspace_id":"ws-1","tab_id":"tab-2","label":"Git","focused":false,"cwd":"$worktree_repo"}]}}
EOF
assert_decision "OPEN" \
  "$repo_root/scripts/open-lazygit-tab.sh" "$main_repo" \
  "$tab_different_worktree_panes" "$current_file" "$process_dir"

if grep -Fq 'not a git repository' "$repo_root/scripts/open-lazygit.sh" "$repo_root/scripts/open-lazygit-tab.sh"; then
  echo 'launcher identity resolution should not inspect localized git stderr text' >&2
  exit 1
fi

printf 'launcher decision tests passed\n'
