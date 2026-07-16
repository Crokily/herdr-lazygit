# herdr-lazygit

[中文文档](README.zh-CN.md)

**One keypress summons a git sidebar right next to your work.** It puts [lazygit](https://github.com/jesseduffield/lazygit) inside [herdr](https://herdr.dev)'s window system: a minimal 42-column single-column panel by default, one key to expand the full lazygit UI, and an AI commit pane that appears before generation starts.

## What it feels like

Press `prefix+g` and a narrow git sidebar slides open next to your current directory (press again to tuck it away — it never stacks duplicates). A typical commit goes like this:

1. **Expand and review**: changed files are listed with M/A/D status colors. Press `U` first: the sidebar expands into the full lazygit layout, with its native diff, history, stash, and command views available;
2. **Pick**: `Space` (or double-click) stages a file. With lazygit expanded, `Enter` opens the selected file so you can stage hunk by hunk using the native interface;
3. **Commit**: press `C`. A commit pane appears immediately with the backend/model and a spinner while AI reads the staged diff. Then select a candidate, edit it in the input, or type your own message and press Enter;
4. **Sync**: `p` pull, `P` push, `f` fetch. One key per verb.

Press `U` again whenever you want the compact sidebar back. **`U` means "expand/collapse lazygit itself"** — once expanded, every stock lazygit interaction works normally instead of being replaced by plugin-specific viewers.

### Three keys are the whole surface

The plugin adds exactly three keys — one verb each; everything else is stock lazygit (press `?` inside for the built-in list):

| Key | Verb | What it does |
| --- | --- | --- |
| `C` | **Commit** | Opens a pane immediately → AI generates → select/edit/write → commit |
| `U` | **Expand** | Toggles lazygit between the compact sidebar and full layout |
| `;` | **Settings** | Opens the settings pane — every knob below lives there |

All three keys are remappable (see below), and the mouse works throughout: click to select, double-click to stage, wheel to scroll.

### The settings pane (`;`)

Press `;` from anywhere in lazygit and a settings pane (fzf-driven, keyboard and mouse) opens beside the sidebar:

- **AI backend**: claude / codex / opencode / gemini — whichever is installed (auto-detected by default);
- **AI model**: per backend — defaults deliberately pick the cheap/fast tier (haiku for claude) so your CLI's expensive default model is never burned on commit messages;
- **AI prompt**: opens in `$EDITOR` — want Chinese messages, emoji, a different format? Edit here;
- **Keys**: remap C / U / ; live — press the new key; collisions with lazygit built-ins are rejected with the owner shown;
- **Widths**: sidebar, expanded lazygit, and AI commit pane columns.

Changes apply **the moment you focus lazygit again** — it hot-reloads its config on focus, no restart.

### What AI commit needs

Any one of these CLIs installed and logged in: `claude`, `codex`, `opencode`, `gemini`. No API keys — it rides your CLI's own login. Generation errors appear inside the commit pane as a readable hint (starting with `(`); press any key to close it. While generation is running, `Ctrl-C` cancels the backend process.

## Install

Requires herdr >= 0.7.0. `lazygit` and `fzf` (used by the settings and AI commit panes) are detected at install time and installed via Homebrew if missing.

```sh
# Install from GitHub (herdr accepts the <owner>/<repo>[/subdir] short form, optional --ref)
herdr plugin install <owner>/<repo>

# Or link a local checkout during development
herdr plugin link /path/to/herdr-lazygit
```

Then add keybindings to your herdr `config.toml` (add them manually):

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

Run `herdr server reload-config` and you're set. `prefix+g` behaves as: not open → open in a split; open but unfocused → focus; focused → close.

> **Note (herdr platform behavior):** an action's context always resolves from the pane that currently has **UI focus**, not from the process that invoked it. Invoking `herdr plugin action invoke …` from a background pane or script opens lazygit next to whatever the user is focused on, takes its cwd from that pane, and steals focus. Only trigger these actions through foreground keybindings.

## Reference

### Key details

- `C` only reads **staged** content — stage first, then press. It overrides the files panel's low-traffic built-in "commit using git editor" (rebind that in `lazygit-user.yml` if you miss it). Only one `GitCommit` pane exists per tab.
- `U` is global and toggles `LAYOUT_MODE` between `sidebar` and `expanded`. Expanded width defaults to 110 columns, clamps to the tab width minus 20 columns, and falls back to the configured 42-column sidebar when collapsed. Reopening the plugin always starts in sidebar mode.
- `U` and `;` are the defaults produced by a **free-key analysis** of every lazygit 0.63.0 built-in binding: candidate `Z` is taken by `universal.redo`, `Ctrl+S` / `O` collide with the filtering and PR menus, while `U` and `;` are unbound in every panel (full occupancy matrix in [DESIGN.md](DESIGN.md) Appendix A). The key-picking rule: **plugin keys must not shadow commonly-used lazygit built-ins** — which is why `v` (range select) and `V` (cherry-pick paste) stay stock.
- Keys persist in `$HERDR_PLUGIN_CONFIG_DIR/keys.conf`.

### AI backend config file

Beyond the settings pane you can hand-edit `$HERDR_PLUGIN_CONFIG_DIR/ai-backend.conf` (shell-sourceable) — the `custom` backend requires it:

```sh
# auto | claude | codex | opencode | gemini | custom
AI_BACKEND=auto

# Used when AI_BACKEND=custom: the command reads prompt+diff on stdin, prints the message to stdout
AI_CUSTOM_CMD=""
```

`detected` only means the CLI is installed — not that it is logged in or eligible; failure hints include the backend name and a one-line stderr summary (e.g. gemini's `IneligibleTierError`).

### Three config layers

The plugin loads three lazygit config layers via `LG_CONFIG_FILE` (later layers win):

1. The bundled base layer `lazygit-config.yml` (factory settings — do not edit, plugin updates overwrite it)
2. The generated layer `$HERDR_PLUGIN_CONFIG_DIR/generated.yml` (written from keys plus layout mode — machine-generated, do not edit)
3. Your override layer `$HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml` (created on first run; always last = always wins)

Scalar settings are overridden field by field; `customCommands` entries accumulate across layers, with the later file winning on the same key + context — so your override layer can replace any plugin command outright. The generated layer owns the mode-dependent `sidePanelWidth` plus fixed `expandFocusedSidePanel: true` / `portraitMode: never`; the base layer keeps mouse support on and random tips off. Neither assumes a Nerd Font (set `gui.nerdFontsVersion: "3"` in your override layer if you have one).

To remap a **plugin** key, use the settings pane (stored in `keys.conf`). To remap a **lazygit built-in**, add a `keybinding` section to `lazygit-user.yml`.

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
  open-ai-commit-pane.sh     # Commit handler: opens/restores the GitCommit pane
  ai-commit-pane.sh          # spinner + fzf message editing + git commit UI
  toggle-expand.sh           # Expand handler: mode, geometry, and focus-in reload
  open-settings-pane.sh      # Settings handler: opens the settings pane
  settings-fzf.sh            # the fzf menu loop inside the settings pane
  gen-config-layer.sh        # keys.conf -> generated.yml (machine-generated layer)
  free-keys.py               # keybinding occupancy analysis / conflict check
  layout-helper.py           # absolute pane geometry over the herdr socket
```

Per-user state lives in `$HERDR_PLUGIN_CONFIG_DIR` (falls back to `~/.config/herdr-lazygit`):

```
keys.conf                    # plugin keys: KEY_COMMIT / KEY_ZOOM / KEY_SETTINGS
panel.conf                   # widths + LAYOUT_MODE(sidebar/expanded)
ai-backend.conf              # AI backend / per-backend model
prompt.txt                   # custom AI commit prompt
generated.yml                # machine-generated lazygit layer — do not edit
lazygit-user.yml             # your lazygit overrides — always wins
```

The full design rationale (three-verb model, lazygit-as-data-engine / herdr-as-window-system, key-picking rules, capability boundaries) lives in [DESIGN.md](DESIGN.md).
