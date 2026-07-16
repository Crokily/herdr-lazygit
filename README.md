# herdr-lazygit

[中文文档](README.zh-CN.md)

A [herdr](https://herdr.dev) plugin that runs [lazygit](https://github.com/jesseduffield/lazygit) in a narrow sidebar pane, with AI commit message generation. Press one key to open the sidebar, one key to expand it into the full lazygit layout, and one key to commit with an AI-written message.

## Daily workflow

Press `prefix+g`. A 42-column git sidebar opens next to your current directory. Press it again and the sidebar closes; the launcher never opens a second copy.

A typical commit:

1. **Review**: the sidebar lists changed files with M/A/D status colors. Press `U` to expand the sidebar into the full lazygit layout — diff view, history, stash, and every native interaction become available;
2. **Stage**: `Space` (or double-click) stages a file. In the expanded layout, `Enter` opens the file and stages individual hunks;
3. **Commit**: press `C`. A commit pane opens immediately, shows the backend and model, and runs a spinner while the AI reads the staged diff. It then lists 3 candidate messages. The bottom of the pane shows the full selected message, a change summary line, and the complete staged diff rendered by delta. Select a candidate, edit it in the input line, or type your own message, then press Enter to commit;
4. **Sync**: `p` pull, `P` push, `f` fetch.

Press `U` again to return to the compact sidebar.

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
- **AI model**: set per backend. Defaults use each provider's cheap, fast tier (haiku for claude), so commit messages never run on an expensive default model;
- **AI prompt**: opens the prompt file in `$EDITOR`. Edit it to change the language or format of generated messages;
- **Keys**: remap C / U / ; by pressing the new key. Keys that collide with a lazygit built-in are rejected, and the conflicting binding is shown;
- **Widths**: sidebar, expanded layout, and commit pane columns.

Changes take effect when the lazygit pane regains focus — lazygit hot-reloads its config files on focus, so no restart is needed.

## What AI commit requires

One of these CLIs installed and logged in: `claude`, `codex`, `opencode`, `gemini`. No API keys are needed; the plugin calls the CLI's non-interactive mode under your existing login. When generation fails, the commit pane shows a hint line starting with `(` that names the backend and the error; press any key to close. `Ctrl-C` cancels a running generation.

## Install

Requires herdr >= 0.7.0. `lazygit` and `fzf` are checked at install time and installed via Homebrew if missing.

```sh
herdr plugin install crokily/herdr-lazygit

# Or link a local checkout during development
herdr plugin link /path/to/herdr-lazygit
```

Then add keybindings to your herdr `config.toml`:

```toml
[[keys.command]]              # lazygit: open in a split
key = "prefix+g"
type = "shell"
command = "herdr plugin action invoke open --plugin herdr-lazygit"

[[keys.command]]              # lazygit: open in its own tab
key = "prefix+shift+g"
type = "shell"
command = "herdr plugin action invoke open-tab --plugin herdr-lazygit"
```

Run `herdr server reload-config`. `prefix+g` then behaves as: not open → open in a split; open but unfocused → focus; focused → close.

> **Note (herdr platform behavior):** an action's context always resolves from the pane that currently has **UI focus**, not from the process that invoked it. Invoking `herdr plugin action invoke …` from a background pane or script opens lazygit next to the user's focused pane, takes its cwd from that pane, and steals focus. Trigger these actions only through foreground keybindings.

## Reference

### Key details

- `C` reads **staged** content only — stage first, then press. It overrides the files panel's built-in "commit using git editor" binding; rebind that in `lazygit-user.yml` if you use it. One `GitCommit` pane exists per tab.
- `U` is a global binding that toggles `LAYOUT_MODE` between `sidebar` and `expanded`. Expanded width defaults to 110 columns and is clamped to the tab width minus 20. Reopening the plugin always starts in sidebar mode.
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

### Three config layers

The plugin loads three lazygit config layers via `LG_CONFIG_FILE`; later layers win:

1. The bundled base layer `lazygit-config.yml` (factory settings — do not edit; plugin updates overwrite it)
2. The generated layer `$HERDR_PLUGIN_CONFIG_DIR/generated.yml` (written from keys and layout mode — machine-generated, do not edit)
3. Your override layer `$HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml` (created on first run; always last, always wins)

Scalar settings are overridden field by field. `customCommands` entries accumulate across layers, and the later file wins on the same key + context, so the override layer can replace any plugin command. The generated layer owns the mode-dependent `sidePanelWidth` plus `expandFocusedSidePanel: true` and `portraitMode: never`; the base layer enables mouse support and disables random tips. Neither sets a Nerd Font (add `gui.nerdFontsVersion: "3"` to your override layer if you use one).

To remap a plugin key, use the settings pane (stored in `keys.conf`). To remap a lazygit built-in, add a `keybinding` section to `lazygit-user.yml`.

### Layout

```
herdr-plugin.toml            # plugin manifest
lazygit-config.yml           # bundled base config (factory layer)
DESIGN.md                    # design doc: three-verb model, key rules, config layers
scripts/
  ensure-lazygit.sh          # install-time: detect/install lazygit
  ensure-fzf.sh              # install-time: detect/install fzf (settings + commit UI)
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
  free-keys.py               # keybinding occupancy analysis / conflict check
  layout-helper.py           # absolute pane geometry over the herdr socket
```

Per-user state lives in `$HERDR_PLUGIN_CONFIG_DIR` (falls back to `~/.config/herdr-lazygit`):

```
keys.conf                    # plugin keys: KEY_COMMIT / KEY_ZOOM / KEY_SETTINGS
panel.conf                   # pane widths + LAYOUT_MODE (sidebar/expanded)
ai-backend.conf              # AI backend / per-backend model
prompt.txt                   # custom AI commit prompt
generated.yml                # machine-generated lazygit layer — do not edit
lazygit-user.yml             # your lazygit overrides — always wins
```

The design rationale — the three-verb model, the split between lazygit (git interactions) and herdr (window management), key-picking rules, and capability boundaries — is documented in [DESIGN.md](DESIGN.md).
