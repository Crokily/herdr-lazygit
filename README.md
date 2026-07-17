# herdr-lazygit

[中文文档](README.zh-CN.md)

A [herdr](https://herdr.dev) plugin that runs [lazygit](https://github.com/jesseduffield/lazygit) in a narrow sidebar pane, with AI commit message generation. Press one key to open the sidebar, one key to expand it into the full lazygit layout, and one key to commit with an AI-written message.

![herdr-lazygit demo](docs/media/demo.gif)

<sub>Demo recorded automatically by Fable 5 with the [promo-gif](https://github.com/Crokily/colys-agent-lab/tree/main/skills/promo-gif) skill.</sub>

## Daily workflow

Press `prefix+g`. A 42-column git sidebar opens next to your current directory. Press it again and the sidebar closes; the launcher never opens a second copy.

A typical commit:

1. **Stage**: the sidebar lists changed files with M/A/D status colors. `Space` (or double-click) stages a file — no expansion needed;
2. **Commit**: press `C`. A commit pane opens immediately, shows the backend and model, and runs a spinner while the AI reads the staged diff. It then lists 3 candidate messages, with the full selected message, a change summary, and the complete staged diff rendered below. Select a candidate, edit it in the input line, or type your own message, then press Enter to commit;
3. **Sync**: `p` pull, `P` push, `f` fetch.

For everyday commits, the sidebar is all you need. When you want a deeper look — full diff view, history, stash, hunk-by-hunk staging with `Enter` — press `U` to expand into the complete lazygit layout, and `U` again to collapse back.

![Expand and collapse with U](docs/media/expand.gif)

## The three plugin keys

The plugin adds exactly three keybindings. Everything else is stock lazygit (press `?` inside lazygit for the built-in list):

| Key | Verb | What it does |
| --- | --- | --- |
| `C` | **Commit** | Opens the AI commit pane: generate, select or edit, commit |
| `U` | **Expand** | Toggles between the compact sidebar and the full lazygit layout |
| `;` | **Settings** | Opens the settings pane |

All three keys are remappable from the settings pane. The mouse works throughout: click to select, double-click to stage, wheel to scroll.

## The settings pane (`;`)

Press `;` from anywhere in lazygit. A settings pane (fzf-driven, keyboard and mouse) opens beside the sidebar:

- **AI backend**: claude / codex / opencode / gemini. Default is auto-detection in that order;
- **AI model**: set per backend. Defaults are `haiku` for claude, `google/gemini-2.5-flash` for opencode, `gemini-2.5-flash` for gemini, and the Codex CLI's configured default for codex. If you want codex pinned to a specific model, set `AI_CODEX_MODEL`;
- **AI prompt**: opens the prompt file in `$EDITOR`. Edit it to change the language or format of generated messages;
- **Keys**: remap C / U / ; by pressing the new key. Keys that collide with a lazygit built-in are rejected, and the conflicting binding is shown;
- **Widths**: sidebar, expanded layout, and commit pane columns.

Changes take effect when the lazygit pane regains focus — lazygit hot-reloads its config files on focus, so no restart is needed.

![The settings pane](docs/media/settings.png)

## What AI commit requires

One of these CLIs installed and logged in: `claude`, `codex`, `opencode`, `gemini`. No API keys are needed; the plugin calls the CLI's non-interactive mode under your existing login. When generation fails, the commit pane shows a hint line starting with `(` that names the backend and the error; press any key to close. `Ctrl-C` cancels a running generation.

### AI data disclosure

Pressing `C` sends the staged diff plus the prompt text for this plugin to the selected AI CLI on this machine. The diff is currently truncated to the first 8,000 characters before it is passed to the CLI.

That CLI then forwards the request to its provider's service under **your** account; that provider's billing, retention, and privacy policies apply. Nothing is sent at any other time. The plugin itself collects nothing and has no telemetry.

![The AI commit pane](docs/media/commit-pane.png)

## Install

Requires herdr >= 0.7.0 plus `bash`, `git`, and Python >= 3.7 (`python3`) on `PATH`. During a GitHub install, the plugin downloads pinned private copies of lazygit 0.63.0 and fzf 0.74.0, verifies repository-pinned SHA-256 digests, and stores them under its managed `bin/` directory. It never invokes Homebrew, a system package manager, or `sudo`. The build also needs `curl` or `wget`, `tar`, and `sha256sum` or `shasum`.

### Why a private lazygit?

The plugin generates lazygit configuration — customCommands, keybindings, layout — tested against exactly lazygit 0.63.0, and its settings menu relies on fzf 0.74.0 features. Pinning private copies means the same plugin version behaves the same on every machine, and users without lazygit get a working pane with no package-manager side effects. The private binaries never enter `PATH` and never conflict with a Homebrew or distro lazygit.

### Your existing lazygit config

The pane loads your own lazygit config file (from the directory `lazygit --print-config-dir` reports) as the base layer, so your theme and settings apply inside the pane. The plugin's layers merge over it — keys the plugin owns still win, and `$HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml` keeps the final say. Set `INHERIT_USER_CONFIG=0` in `$HERDR_PLUGIN_CONFIG_DIR/panel.conf` to opt out. If your personal config was written for a newer lazygit and the pinned one rejects it, the pane stays open and shows the error instead of closing silently.

### Using your own binaries

Absolute paths in `$HERDR_PLUGIN_CONFIG_DIR/panel.conf` bypass the private runtime:

```sh
RUNTIME_LAZYGIT_BIN='/opt/homebrew/bin/lazygit'
RUNTIME_FZF_BIN='/opt/homebrew/bin/fzf'
```

A version other than the pinned one prints a warning and is unsupported — generated keybindings and config may misbehave.

### Installing behind a firewall

The runtime downloads from GitHub releases. If the build cannot reach GitHub, run the installer manually with mirror overrides (paths mirror the upstream `releases/download` layout); repository-pinned SHA-256 digests still verify whatever the mirror serves:

```sh
HERDR_LAZYGIT_LAZYGIT_BASE_URL='https://your-mirror/jesseduffield/lazygit/releases/download' \
HERDR_LAZYGIT_FZF_BASE_URL='https://your-mirror/junegunn/fzf/releases/download' \
  /bin/sh scripts/install-runtime.sh
```

```sh
herdr plugin install crokily/herdr-lazygit

# Local development: plugin link does not run [[build]], so prepare the runtime first.
cd /path/to/herdr-lazygit
/bin/sh scripts/install-runtime.sh
herdr plugin link "$PWD"
```

Then add keybindings to your herdr `config.toml`:

```toml
[[keys.command]]              # lazygit: open in a split
key = "prefix+g"
type = "plugin_action"
command = "herdr-lazygit.open"

[[keys.command]]              # lazygit: open in its own tab
key = "prefix+shift+g"
type = "plugin_action"
command = "herdr-lazygit.open-tab"
```

Run `herdr server reload-config`. `prefix+g` then behaves as: not open → open in a split; open but unfocused → focus; focused → close.

> **Note (herdr platform behavior):** an action's context always resolves from the pane that currently has **UI focus**, not from a background process. The action opens lazygit next to the user's focused pane, takes its cwd from that pane, and focuses the new pane. Trigger these actions only through foreground keybindings.

## Reference

### Key details

- `C` reads **staged** content only — stage first, then press. It overrides the files panel's built-in "commit using git editor" binding; rebind that in `lazygit-user.yml` if you use it. One `GitCommit` pane exists per tab.
- `U` is a global binding that toggles the current pane's per-instance layout layer between `sidebar` and `expanded`. Expanded width defaults to 110 columns and is clamped to the tab width minus 20. Every new pane starts in sidebar mode, and other panes keep their own mode.
- `U` and `;` are the defaults produced by a free-key analysis of every lazygit 0.63.0 built-in binding: candidate `Z` is taken by `universal.redo`; `Ctrl+S` and `O` collide with the filtering menu and the PR menu; `U` and `;` are unbound in every panel (full occupancy matrix in [DESIGN.md](DESIGN.md) Appendix A). The key-picking rule: plugin keys must not shadow commonly used lazygit built-ins. `v` (range select) and `V` (cherry-pick paste) stay stock for the same reason.
- Keys persist in `$HERDR_PLUGIN_CONFIG_DIR/keys.conf`.

### AI backend config file

The settings pane writes `$HERDR_PLUGIN_CONFIG_DIR/ai-backend.conf` (shell-sourceable). It can also be edited by hand — the `custom` backend requires it:

```sh
# auto | claude | codex | opencode | gemini | custom
AI_BACKEND=auto

# Used when AI_BACKEND=custom: the command reads prompt+diff on stdin, prints the message to stdout
AI_CUSTOM_CMD=""
```

`detected` in the settings pane means the CLI is installed; it does not guarantee the CLI is logged in or eligible. Failure hints include the backend name and a one-line stderr summary.

### Config layers

The plugin loads four plugin-managed lazygit config layers via `LG_CONFIG_FILE`; later layers win:

1. The bundled base layer `lazygit-config.yml` (factory settings — do not edit; plugin updates overwrite it)
2. The generated global layer `$HERDR_PLUGIN_CONFIG_DIR/generated.yml` (written from keys/customCommands — machine-generated, do not edit)
3. The per-pane layout layer `$HERDR_PLUGIN_CONFIG_DIR/layout-<pid>-<epoch>.yml` (written on pane start and by `U`; stores only this pane's sidebar/expanded state)
4. Your override layer `$HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml` (created on first run; always last, always wins)

Scalar settings are overridden field by field. `customCommands` entries accumulate across layers, and the later file wins on the same key + context, so the override layer can replace any plugin command. The per-pane layout layer owns the mode-dependent `sidePanelWidth` plus `expandFocusedSidePanel: true` and `portraitMode: never`; the base layer enables mouse support and disables random tips. Neither sets a Nerd Font (add `gui.nerdFontsVersion: "3"` to your override layer if you use one).

To remap a plugin key, use the settings pane (stored in `keys.conf`). To remap a lazygit built-in, add a `keybinding` section to `lazygit-user.yml`.

### Layout

```
herdr-plugin.toml            # plugin manifest
lazygit-config.yml           # bundled base config (factory layer)
DESIGN.md                    # design doc: three-verb model, key rules, config layers
THIRD_PARTY_NOTICES.md       # licenses for downloaded lazygit/fzf binaries
bin/                         # generated private lazygit + fzf runtime (not committed)
scripts/
  install-runtime.sh         # install-time: download + verify the private runtime
  runtime-versions.sh        # pinned lazygit/fzf versions
  runtime-env.sh             # resolve runtime tools by absolute path
  run-lazygit.sh             # pane entrypoint: regenerate config layer, exec lazygit
  open-lazygit.sh            # action: open in a split (idempotent open/focus/toggle)
  open-lazygit-tab.sh        # action: open in a tab
  ai-commit-msg.sh           # AI commit message generation / backend & model management
  open-ai-commit-pane.sh     # Commit handler: opens the GitCommit pane
  ai-commit-pane.sh          # spinner + fzf candidate/preview UI + git commit
  toggle-expand.sh           # Expand handler: mode, geometry, focus-in hot reload
  open-settings-pane.sh      # Settings handler: opens the settings pane
  settings-fzf.sh            # the fzf menu loop inside the settings pane
  gen-config-layer.sh        # keys.conf -> generated.yml (machine-generated layer)
  layout-layer.sh            # per-pane layout layer read/write helpers
  free-keys.py               # keybinding occupancy analysis / conflict check
  layout-helper.py           # absolute pane geometry over the herdr socket
```

Per-user state lives in `$HERDR_PLUGIN_CONFIG_DIR` (falls back to `~/.config/herdr-lazygit`):

```
keys.conf                    # plugin keys: KEY_COMMIT / KEY_ZOOM / KEY_SETTINGS
panel.conf                   # global pane widths + optional INHERIT_USER_CONFIG / RUNTIME_* overrides
ai-backend.conf              # AI backend / per-backend model
prompt.txt                   # custom AI commit prompt
generated.yml                # machine-generated global lazygit layer — do not edit
layout-<pid>-<epoch>.yml     # machine-generated per-pane layout layer — do not edit
lazygit-user.yml             # your lazygit overrides — always wins
```

The design rationale — the three-verb model, the split between lazygit (git interactions) and herdr (window management), key-picking rules, and capability boundaries — is documented in [DESIGN.md](DESIGN.md).

## License

This repository is licensed under the [MIT License](LICENSE). The bundled lazygit/fzf runtime is covered separately in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
