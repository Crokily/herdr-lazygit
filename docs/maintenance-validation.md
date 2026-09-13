# Maintenance validation — 2026-09-13

This branch keeps the manifest at its existing version until a release is
chosen. It retains `min_herdr_version = "0.7.0"` and Linux/macOS platform support.
Windows is limited to the [contribution review and CI plan](windows-review.md).

## Evidence and boundaries

Before implementation, isolated probes reproduced both original launchers
waiting 10.06 seconds on an occupied lock and returning status 0 with empty
stdout/stderr. Herdr CLI children inherited descriptor 9; an injected hanging
`pane list` retained the lock. The exact nested-shell chain described in issue
#5 was not reproduced, so this branch does not claim that specific root cause
has been proven.

The implementation removes inherited lock ownership and pipe-EOF waits from
launcher commands, bounds command and overall execution, and reports errors.
Tests cover a descendant retaining output, a hung query, nested helper
termination, concurrent creation, a busy lock, distinct server/workspace
scopes, and a creation that succeeds server-side but times out for the caller.

## Local validation

Host: Linux ARM64. All tests use temporary repositories and configuration.
The real-Herdr tests create their own server, client PTY and sockets, link this
checkout only in that private registry, and shut down only their own processes.
AI generation uses a local stub; cancellation is verified not to create a commit.

| Check | Result |
| --- | --- |
| Existing installer, runtime integration/resolution, worktree identity, layout isolation and AI diff sampling suites | Passed |
| Stateful launcher behavior, geometry compatibility and initial-layout settings suites | Passed |
| Real Herdr 0.7.0 + lazygit 0.65.0 + fzf 0.74.4 | Passed |
| Real Herdr 0.7.5 + the same runtime | Passed |
| Real Herdr 0.8.2 + the same runtime | Passed |
| Real Herdr 0.9.0 + the same runtime | Passed |
| Bash/POSIX installer syntax, Python syntax, workflow YAML and diff whitespace | Passed |
| macOS/Linux x86_64 and ARM64 runtime archives (8 files) | Downloaded and SHA-256 matched against official checksum files and GitHub asset digests |

Each real-Herdr run exercises manifest action launch, actual lazygit/fzf
processes, C/U/;, support-pane cancellation and width restoration, sidebar
split and expanded tab defaults, an explicit expanded split preference,
same-workspace reuse, cross-tab focus, toggle close, full-tab width preservation,
and a runtime failure recorded as failed rather than succeeded.

The 0.7.0 run confirmed that `layout.set_split_ratio` is absent. Its tested
fallback uses the official `pane.resize` API and preserves terminals. The
`layout.apply` API was rejected as a fallback because it recreates terminals.
Older Herdr versions need an attached client to update geometry during these
tests; the fixture supplies a private PTY client for that purpose.

The real 0.65.0 default key table still has 167 actions across 11 sections.
U and ; remain free globally; C retains its documented files-panel exception.
Handwritten conflicts now select a free plugin key without disabling native
actions or overwriting saved preferences.

## CI and remaining manual checks

The workflow runs the hermetic suites on Ubuntu/macOS and adds real runtime
tests for all four Herdr versions on both platforms. These new hosted jobs
have not been run from this local branch. Only Linux ARM64 binaries were
executed locally; checksum verification is not execution evidence for the
other architectures.

Two simultaneous client views and real SSH/saved-machine reconnects remain
manual integration checks. Stateful tests cover changed focus and server scope,
but do not establish end-to-end multi-client/remote UI behavior. Notifications
are best effort: a disconnected server cannot display one, while action stderr
still retains the reason. Wide/narrow visual ergonomics and mouse interactions
also need manual terminal checks beyond the scripted key/API tests.

To reproduce the real test after installing the private runtime:

```sh
/bin/sh scripts/install-runtime.sh
python3 tests/herdr-smoke-test.py /absolute/path/to/herdr
```
