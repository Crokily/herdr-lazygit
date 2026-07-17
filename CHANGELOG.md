# Changelog

Notable changes to the herdr-lazygit plugin. Versions track `version` in
`herdr-plugin.toml`; the format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Top-level MIT `LICENSE` for the repository (`Copyright (c) 2026 Crokily`).
- Explicit Gemini model pinning support through `AI_GEMINI_MODEL`, defaulting to
  `gemini-2.5-flash` unless the variable is set to an empty string to defer to
  the Gemini CLI default.
- README and `README.zh-CN.md` AI data-disclosure sections explaining that
  pressing `C` sends the staged diff (currently truncated to 8,000
  characters) plus the plugin prompt text to the selected local AI CLI, which
  then forwards it to the provider under the user's account; the plugin itself
  has no telemetry.

### Fixed

- Multiple lazygit panes no longer overwrite each other's sidebar/expanded
  state: `LAYOUT_MODE` was removed from global `panel.conf`, the shared
  `generated.yml` no longer carries layout-specific GUI state, and each pane
  now gets its own `layout-<pid>-<epoch>.yml` layer that starts in sidebar
  mode and is cleaned up opportunistically on future startups.
- The README model-cost claim now states the real defaults: claude uses
  `haiku`, opencode uses `google/gemini-2.5-flash`, gemini uses
  `gemini-2.5-flash`, and codex uses the Codex CLI's configured default unless
  `AI_CODEX_MODEL` is set.
- The `open` / `open-tab` launchers no longer reuse a `Git` pane from the
  wrong repository or a different worktree of the same repository; reuse now
  requires the same git worktree (or the same directory for non-git targets).

## [0.2.0] - 2026-07-17

### Added

- The pane now loads your own lazygit config file (from the directory
  `lazygit --print-config-dir` reports) as the base config layer, so an
  existing lazygit user keeps their theme and settings. The plugin's layers
  still win for the keys they own. Opt out with `INHERIT_USER_CONFIG=0` in
  `panel.conf`.
- `RUNTIME_LAZYGIT_BIN` / `RUNTIME_FZF_BIN` in `panel.conf` substitute your own
  binaries for the private runtime (unsupported; a version other than the
  pinned one prints a warning).
- README sections on the private-runtime rationale, config inheritance, binary
  overrides, and installing via a mirror behind a firewall.
- Hermetic test suite for runtime resolution and config layering
  (`tests/runtime-resolution-test.sh`), wired into CI.

### Changed

- Pane startup failures are now visible: the pane runs lazygit as a child
  process and, on a non-zero exit, stays open showing the error, the config
  layers, and how to opt out of inheritance — instead of closing instantly.
- The `open` / `open-tab` launchers precheck the resolved runtime before
  opening a pane; a missing or broken runtime now fails the action with a
  readable error in `herdr plugin log list`.

## [0.1.1] - 2026-07-16

### Added

- Pinned private runtime: the `[[build]]` step downloads lazygit 0.63.0 and
  fzf 0.74.0 release archives for macOS/Linux (x86_64/arm64), verifies
  repository-pinned SHA-256 digests, and installs them under the plugin's
  `bin/` — no Homebrew, package manager, or `sudo`.
- `HERDR_LAZYGIT_LAZYGIT_BASE_URL` / `HERDR_LAZYGIT_FZF_BASE_URL` mirror
  overrides for the runtime download.
- Atomic publish with rollback: a failed install can never leave a mixed or
  partial `bin/` runtime.
- Runtime installer and integration test suites, run by CI on Ubuntu and macOS.

### Changed

- **Breaking for linked checkouts:** the plugin no longer uses lazygit or fzf
  from `PATH` and no longer brew-installs anything (`ensure-lazygit.sh` /
  `ensure-fzf.sh` removed). `herdr plugin link` setups must run
  `/bin/sh scripts/install-runtime.sh` once — herdr does not execute build
  commands for linked plugins.

## [0.1.0] - 2026-07-16

Initial release.

- lazygit in a herdr split pane (`open`) or its own tab (`open-tab`), with an
  idempotent open / focus / close toggle and a launcher lock against key
  auto-repeat races.
- AI commit messages in a dedicated pane (`C`): claude / codex / opencode /
  gemini CLIs or a custom command, generation retry, in-place editing, model
  and prompt configuration.
- `V` opens the selected file, commit, or stash diff in a herdr pane beside
  the sidebar; `U` expands lazygit itself and collapses it back.
- In-pane settings page (`;`): an fzf menu for backend, model, prompt, keys,
  and pane widths.
- Three-layer lazygit config (bundled + generated + user override) and
  `free-keys.py` occupancy analysis so plugin keys never shadow lazygit
  built-ins; key conflicts are rejected at settings time.
- English and Chinese READMEs, DESIGN.md, and an automated demo GIF.
