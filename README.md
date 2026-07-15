# herdr-lazygit

[中文文档](README.zh-CN.md)

A [herdr](https://herdr.dev) plugin that summons [lazygit](https://github.com/jesseduffield/lazygit) with one keypress, with built-in AI commit message generation.

- Opens lazygit in a split pane or its own tab, in the directory of your currently focused pane
- Idempotent launcher: triggering again focuses / toggles the existing pane instead of stacking duplicates
- Press `C` to have an AI read your staged diff and propose 3 conventional-commit candidates — pick one to commit
- Press `KEY_ZOOM` to zoom the selected file / commit / stash entry into a wide herdr pane
- Press `KEY_SETTINGS` to open the plugin's settings pane (AI backend / model / prompt, key remapping, pane widths)

Design rationale (the three-verb model, key-picking rules, config layering) lives in [DESIGN.md](DESIGN.md).

## Install

Requires herdr >= 0.7.0. `lazygit` and `fzf` (used by the settings pane) are detected at install time and installed via Homebrew if missing.

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

`prefix+g` then behaves as: not open → open in a split; open but unfocused → focus; focused → close.

> **Note (herdr platform behavior):** an action's context always resolves from the pane that currently has **UI focus**, not from the process that invoked it. Invoking `herdr plugin action invoke …` from a background pane or script opens lazygit next to whatever the user is focused on, takes its cwd from that pane, and steals focus. Only trigger these actions through foreground keybindings.

## Key reference

The plugin adds exactly three keys — one per verb; everything else is stock lazygit (press `?` inside lazygit for the full list):

| Key | Panel | Action |
| --- | --- | --- |
| `C` | Files | **AI commit message**: reads the staged diff, pops a candidate menu, Enter commits (overrides the files panel's low-traffic default "commit using git editor") |
| `KEY_ZOOM`\* | Files / Commits / Stash | **Zoom**: opens the selected file's diff, the selected commit, or the selected stash entry in a wide herdr pane |
| `KEY_SETTINGS`\* | Global | **Settings**: opens the plugin settings pane |
| `Space` | Files | Stage / unstage the selected file |
| `d` | Files | Discard changes to the selected file |
| `v` | Files/lists | Range select (lazygit built-in) |
| `V` | Commits | Paste cherry-picked commits (lazygit built-in) |
| `o` | Files | Open file with the OS default app |
| `e` | Files | Open file in your editor |
| `f` | Files | Fetch |
| `p` | Global | Pull |
| `P` | Global | Push |
| `z` | Global | Undo the last operation (reflog-based) |
| `?` | Global | Open the keybinding help menu |

\* `KEY_ZOOM` / `KEY_SETTINGS` are placeholders — the final default keys are picked by the free-key analysis during integration (zoom candidates in order `Z` > `U` > `X`; settings candidates `Ctrl+S` > `O` > `;` > `,`; see DESIGN.md Appendix A) and this table will be updated then. All three plugin keys can be remapped from the settings pane; they persist in `$HERDR_PLUGIN_CONFIG_DIR/keys.conf`.

### Using `C` (AI commit)

- Stage the files you want to commit with `Space` first, then press `C`.
- The candidate menu calls the AI CLI before it opens — expect a few seconds.
- With nothing staged, no usable backend, or a generation timeout, the menu shows a hint line starting with `(`; selecting such a line does **not** commit — it just echoes the hint to the command log, so pressing Enter to dismiss it is safe.
- Generated messages are single-line, English, conventional-commit style (`feat:` / `fix:` / `chore:` …).
- AI backend, model, and prompt are all configured from the settings pane (`KEY_SETTINGS`).

### Using `KEY_ZOOM` (zoom)

Zoom opens the selected item in a wide pane to the right of the lazygit sidebar, rendered through [delta](https://github.com/dandavison/delta) if installed (plain `less` otherwise). Press `q` to close the pane; the sidebar returns to its configured width. Only one zoom pane exists at a time.

- **Files panel**: the selected file's diff (staged + unstaged; untracked files diffed against `/dev/null`)
- **Commits / sub-commits / reflog panels**: `git show` of the selected commit
- **Stash panel**: the selected stash entry's patch

### Using `KEY_SETTINGS` (settings pane)

Press `KEY_SETTINGS` from anywhere in lazygit to open an fzf-driven settings pane beside the sidebar. Requires `fzf` (installed by the plugin's install step; if missing, the pane prints `brew install fzf` instructions).

- Menu items: AI backend / AI model / AI prompt (`$EDITOR`) / Key: Commit / Key: Zoom / Key: Settings / Sidebar width / Zoom width
- The preview column shows each item's current value; Enter (or double-click) edits it; `Esc`/`q` exits
- Key remapping prompts you to press the new key and rejects it if it collides with a lazygit built-in (the conflict owner is shown)
- Changes are written immediately and take effect **as soon as you focus the lazygit pane again** — lazygit hot-reloads its config files on focus, no restart needed

## AI backend configuration

The `C` command relies on any one of these installed AI CLIs: `claude`, `codex`, `opencode`, `gemini`.

- Default mode is `auto`: the first available backend wins, probed in the order `claude > codex > opencode > gemini`.
- Switch backend / model from the settings pane. `detected` only means the CLI is installed — not that it is logged in or eligible; on generation failure the hint line includes the backend name and a one-line stderr summary (e.g. gemini's `IneligibleTierError`) so you can fix the login or switch backends.
- The choice persists in `$HERDR_PLUGIN_CONFIG_DIR/ai-backend.conf` (shell-sourceable), which you can also edit by hand — e.g. the `custom` backend needs a manual `AI_CUSTOM_CMD`:

```sh
# auto | claude | codex | opencode | gemini | custom
AI_BACKEND=auto

# Used when AI_BACKEND=custom: the command reads prompt+diff on stdin, prints the message to stdout
AI_CUSTOM_CMD=""
```

## Customizing lazygit

The plugin loads three config layers via `LG_CONFIG_FILE` (later layers win):

1. The bundled base layer `lazygit-config.yml` (factory settings — do not edit, plugin updates overwrite it)
2. The generated layer `$HERDR_PLUGIN_CONFIG_DIR/generated.yml` (written by the settings pane / generator — machine-generated, do not edit)
3. Your override layer `$HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml` (created on first run; always last = always wins)

Scalar settings are overridden field by field; `customCommands` entries accumulate across layers, with the later file winning on the same key + context — so your override layer can replace any plugin command outright. The base layer stays minimal (mouse support on, random tips off) and doesn't assume a Nerd Font (set `gui.nerdFontsVersion: "3"` in your override layer if you have one).

To remap a **plugin** key, use the settings pane (stored in `keys.conf`). To remap a **lazygit built-in** (e.g. to get "commit using git editor" back on some key after `C` shadows it), add a `keybinding` section to `lazygit-user.yml`.

## Layout

```
herdr-plugin.toml            # plugin manifest
lazygit-config.yml           # bundled base config (factory layer)
DESIGN.md                    # design doc: three-verb model, key rules, config layers
scripts/
  ensure-lazygit.sh          # install-time: detect/install lazygit
  ensure-fzf.sh              # install-time: detect/install fzf (settings pane)
  run-lazygit.sh             # pane entrypoint: regenerate config layer, exec lazygit
  open-lazygit.sh            # action: open in a split (idempotent open/focus/toggle)
  open-lazygit-tab.sh        # action: open in a tab
  ai-commit-msg.sh           # AI commit message generation / backend & model management
  show-diff-pane.sh          # Zoom handler: wide pane for file / commit / stash
  open-settings-pane.sh      # Settings handler: opens the settings pane
  settings-fzf.sh            # the fzf menu loop inside the settings pane
  gen-config-layer.sh        # keys.conf -> generated.yml (machine-generated layer)
  free-keys.py               # keybinding occupancy analysis / conflict check
  layout-helper.py           # absolute pane geometry over the herdr socket
```

Per-user state lives in `$HERDR_PLUGIN_CONFIG_DIR` (falls back to `~/.config/herdr-lazygit`):

```
keys.conf                    # plugin keys: KEY_COMMIT / KEY_ZOOM / KEY_SETTINGS
panel.conf                   # widths: SIDEBAR_COLS / DIFF_COLS / SETTINGS_COLS
ai-backend.conf              # AI backend / per-backend model
prompt.txt                   # custom AI commit prompt
generated.yml                # machine-generated lazygit layer — do not edit
lazygit-user.yml             # your lazygit overrides — always wins
```
