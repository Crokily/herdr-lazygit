# Windows contribution review and CI plan

Status: code review only. No Windows support claim or Windows platform entry
is added by this maintenance branch. A Windows test machine is not currently
available to the maintainer. Linux/macOS tests cannot establish native Windows
terminal behavior.

## Candidate and attribution

Reviewed Steven Klar's [Windows contribution, e318235](https://github.com/stevenklar/herdr-lazygit/commit/e318235c35f07b638cb12f53dc4f75ab9383e4d0)
(31 changed files, based on the mainline before this maintenance work).
Retain Steven Klar's original authorship when incorporating that work. If it
is split or adapted, record the source commit and appropriate co-authorship;
do not present the port as a new implementation by the maintainer.

Its division of responsibilities is suitable: PowerShell locates Git Bash and
performs native installation; shared Bash/Python scripts retain the plugin
behavior. The candidate needs to be reconciled with the new shared launcher,
initial-layout preferences, and updated runtime assets before integration.
The new Unix launcher also uses SIGALRM and process-group cleanup. A Windows
adapter must supply tested native deadline/child-process cleanup semantics;
substituting only the lock implementation will not complete the port.

## Findings from source inspection

These are source-level findings; Windows reproduction is still required.

| Area | Evidence in the candidate | Required change / verification |
| --- | --- | --- |
| Lock ownership | `platform.sh` removes a lock directory based only on `find -mmin +1`; it does not verify the owner has exited. Contention also still returns success silently. | Use a non-inherited native OS lock with bounded acquisition, matching the Unix launcher contract. Verify termination releases it and live owners are never displaced merely by age. The maintenance launcher's `fcntl` implementation itself is Unix-only. |
| Installer rollback | `install-runtime.ps1` suppresses restore errors and then removes the backup directory regardless of whether restoration succeeded. | Preserve recoverable binaries and report their location when rollback fails. Inject a failed second publication and a failed restoration separately. |
| fzf shell | `platform.sh` depends on an 8.3 short path for Git Bash under `Program Files`; if no space-free path exists, it keeps fzf's cmd default while previews contain POSIX commands. | Make interpreter/path selection explicit and test with 8.3 names unavailable. A settings menu that starts but cannot preview is not a successful port. |
| UNC paths | PowerShell strips `\\?\` without converting `\\?\UNC\server\share` to `\\server\share`. Bash has a UNC conversion, but PowerShell can corrupt the path before handing it over. | Exercise drive, verbatim, UNC, and verbatim UNC paths through the entire bootstrap chain, including plugin roots. |
| Layout transport | The ctypes named-pipe adapter uses synchronous read/write without a request deadline. | Validate the official Herdr wire protocol and pipe naming on the tested version; bound connect/read/write, handle partial responses, and close handles on every exit. Do not substitute an undocumented endpoint. |
| Pane identification | Windows broadens matching to any process command line containing `lazygit`, including the PowerShell bootstrap. | Recognize the plugin's entrypoint during startup without treating arbitrary command text as ownership. Test failed startup, unrelated Git labels, and rapid repeat actions. |
| Public action IDs | The candidate adds `open-windows`, `open-tab-windows`, and `lazygit-windows` because platform gating does not allow duplicate IDs. | Verify manifest parsing on the Windows-supported Herdr versions and document the exact bindings. Keep the existing Unix action IDs. |

Additional path cases: Unicode user names, spaces, single quotes, LF/CRLF,
native Python versus Git Bash paths, `python3` missing while `python` or `py -3`
works, Microsoft Store Python aliases, and WSL's `bash.exe` appearing first on
PATH. Native Windows and WSL are distinct test targets.

## CI stages after the port is adapted

Do not enable a nominally green Windows job against the current Unix-only
launcher. Add each stage with executable tests when its implementation lands.

1. **Native installation, on `windows-latest`.** Parse all PowerShell files;
   install Git for Windows and a real supported Python in the fixture; run the
   PowerShell installer using official archives. Verify both binaries and the
   repository-pinned Windows SHA-256 values. Test mirrors, corrupt archives,
   missing prerequisites, locked destinations, rollback, and preserved recovery
   files. Also exercise Windows PowerShell 5.1: syntax checking only under
   `pwsh` does not validate the manifest's `powershell` bootstrap.
2. **Shared behavior under Git Bash.** Port the behavioral tests for initial
   modes, preserved user configuration, worktree identities, concurrent
   launchers, deadline handling, and descriptor/handle ownership. Keep native
   Python and Bash PID models separate; do not assert that one PID namespace
   automatically identifies the other. Use Windows-native binary/config paths
   when crossing into lazygit/fzf.
3. **Real Herdr in a disposable server.** Adapt `tests/herdr-smoke-test.py` to
   native Windows process and pipe APIs. Verify the manifest launchers, C/U/;,
   split and tab defaults, reuse, focus, width restoration and pane closing.
   Use an isolated staged repository and a local fake AI backend. No existing
   user server or paid AI CLI participates in these tests.
4. **Interactive validation.** Record terminal, shell, Herdr, lazygit/fzf,
   Windows version and architecture. Check mouse input, preview rendering,
   resize, focus return, escaping/cancellation and Unicode display. A hosted
   runner can prove installation and API behavior; record visual/interactive
   gaps separately instead of inferring them from `--version` output.

Run the complete Unix regression suite alongside the Windows jobs. Test x64
first; record ARM64 archive verification and actual execution independently.
The presence of an ARM64 asset does not establish an ARM64 support claim.

## Runtime and release boundary

The port should use the maintenance branch's lazygit 0.65.0 and fzf 0.74.4,
adding the four Windows asset digests to the installer from the official
release checksums. Preserve the existing private-runtime design and explicit
user overrides. Keep the minimum Herdr version based on evidence; Linux/macOS
0.7 compatibility does not establish a Windows minimum.

Only enable `windows` in the manifest and publish Windows installation
instructions when the claimed scope has passing native tests and recorded
interactive evidence. Choosing a release version is a separate decision.
