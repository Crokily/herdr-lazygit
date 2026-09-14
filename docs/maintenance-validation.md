# Maintenance validation — 2026-09-13–14

This maintenance work is included in version 0.4.0. It retains `min_herdr_version = "0.7.0"` and Linux/macOS platform support.
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

The initial September 13 smoke assertions checked layout YAML, pane geometry
and server-side focus. They did **not** establish that the client's visible
tab switched or that lazygit actually showed the expanded diff. The follow-up
below corrects that evidence gap.

The 0.7.0 run confirmed that `layout.set_split_ratio` is absent. Its tested
fallback uses the official `pane.resize` API and preserves terminals. The
`layout.apply` API was rejected as a fallback because it recreates terminals.
Older Herdr versions need an attached client to update geometry during these
tests; the fixture supplies a private PTY client for that purpose.

The real 0.65.0 default key table still has 167 actions across 11 sections.
U and ; remain free globally; C retains its documented files-panel exception.
Handwritten conflicts now select a free plugin key without disabling native
actions or overwriting saved preferences.

## Client focus and rendered layout follow-up — September 14

The macOS/Ghostty report reproduced a Git tab created in the background on
Herdr 0.9.0 even though the action log and server pane metadata reported
success. Source inspection of Herdr tag `v0.9.0`
(`b99002ac99b09e00b4ca692436cb15a6b0d676f1`) identifies the cause: the public
request handler projects ordinary tab/pane/workspace focus into client views,
but omits plugin pane open/focus from that path. Removing explicit workspace
targeting does not address this omission.
See the [public focus projection](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/server/headless/client_views.rs#L803-L872).

The launcher now retains the invoking workspace and explicitly focuses the
tab ID returned by creation. Cross-tab reuse selects the existing plugin pane
and then its tab. A failed focus operation reports an error; a later invocation
reuses the already-created pane instead of creating a duplicate. The stateful
suite includes this timeout/reuse case and now has 18 tests. Canonical path
comparison fixes macOS `/var` versus `/private/var` test assertions, and
bootstrap recognition also accepts aliases of the exact entrypoint script.

This is a session-wide compatibility fix. Herdr 0.9's public `tab.focus`
[updates all attached shell clients](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/server/headless/client_views.rs#L165-L189),
and its [plugin invocation context](https://github.com/herdrdev/herdr/blob/b99002ac99b09e00b4ca692436cb15a6b0d676f1/src/api/schema/plugins.rs#L364-L400)
does not identify the originating client. Strictly client-local switching
requires an upstream context/routing extension. This branch does not claim
to provide it.

The Mac tester also verified five consecutive visible `U` toggles after
changing the injected sequence to focus-out followed by focus-in. That fix is
included: a repeated focus-in by itself can be ignored by an already-focused
lazygit. The updated real-runtime test:

- Establishes focused state, presses `U` five times, and checks actual visible
  pane cells for the staged diff in expanded mode and its absence in sidebar mode.
- Reconstructs the real client's current 180×45 terminal grid with pinned
  test-only `pyte`, rather than searching accumulated terminal output.
- Verifies client rendering after cross-tab reuse and new tab creation.
- Sends the configured `prefix+shift+g` through the client PTY, returns to the
  source tab twice and repeats it, checking visible diff content and reuse of
  the same single Git pane.

Negative controls ran the updated test against disposable copies of the current
checkout with one file restored from baseline `59cd3f5`: restoring only its
launcher failed at `visible client cross-tab switch`; restoring only its
focus-in toggle failed at `rendered diff after Expand`. These assertions
therefore detect both reported regressions.

Herdr 0.7.0 initially rejected the test's custom `prefix+shift+g` binding in
favor of its default new-worktree action. The fixture explicitly unbinds that
default with `[keys] new_worktree = []`; the README documents the same conflict
for users. This configuration adjustment does not change plugin runtime code.

With that explicit fixture configuration, the updated rendering test passed on
Linux ARM64 with Herdr 0.7.0, 0.7.5, 0.8.2 and 0.9.0, lazygit 0.65.0 and fzf
0.74.4. All nine hermetic suites also passed, including the 18 launcher behavior
tests and six geometry tests.

## CI and remaining manual checks

The workflow runs the hermetic suites on Ubuntu/macOS and adds real runtime
tests, including rendered client assertions, for all four Herdr versions on
both platforms. Terminal emulation dependencies are isolated in a test venv;
the plugin runtime still has no Python package dependencies. The first hosted
run passed nine of ten jobs. The macOS/Herdr 0.7.0 job failed inside pyte's
screen reader: overwriting the first cell of a Chinese wide character can leave
an empty continuation cell, which pyte 0.8.2's `display` indexes as a nonempty
string. A minimal ANSI replay reproduces the same `IndexError` locally.
The test adapter now renders orphan continuation cells as blanks, with
regressions for partial repaints, intact wide/combining characters and cleared
diff content. The existing visible-client assertions remain in place. All ten
hosted jobs passed on `c147c52`, covering both Ubuntu and macOS and all four
Herdr versions ([CI run](https://github.com/Crokily/herdr-lazygit/actions/runs/34794929041)).
Only Linux ARM64 binaries were executed locally;
checksum verification is not execution evidence for the other architectures.

The post-merge run exposed a separate fixture race on Ubuntu/Herdr 0.7.5:
Git rendered before the asynchronous keybinding action's final focus request
completed. The fixture could switch back to its source tab too soon, then be
switched away by the still-running action. Keyboard tests now wait for the
new action log to report success before changing tabs, while still requiring
actual rendered diff content. Failed actions remain test failures.

After testing the follow-up commit `bba1350`, the maintainer confirmed on
September 14 that the fixes work in the reported macOS/Ghostty environment
with Herdr 0.9.0, including the tab-switch fix. This is maintainer-reported
manual verification, separate from the automated Linux ARM64 results above.

Two simultaneous client views and real SSH/saved-machine reconnects remain
manual integration checks. Stateful tests cover changed focus and server scope,
but do not establish end-to-end multi-client/remote UI behavior. Notifications
are best effort: a disconnected server cannot display one, while action stderr
still retains the reason. Wide/narrow visual ergonomics and mouse interactions
also need manual terminal checks beyond the scripted key/API tests.

To reproduce the real test after installing the private runtime:

```sh
/bin/sh scripts/install-runtime.sh
python3 -m venv /tmp/herdr-lazygit-tests
/tmp/herdr-lazygit-tests/bin/python -m pip install -r tests/requirements.txt
/tmp/herdr-lazygit-tests/bin/python tests/herdr-smoke-test.py /absolute/path/to/herdr
```
