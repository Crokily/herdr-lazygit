# herdr-lazygit

[中文文档](README.zh-CN.md)

A [herdr](https://herdr.dev) plugin that summons [lazygit](https://github.com/jesseduffield/lazygit) with one keypress, with built-in AI commit message generation.

- Opens lazygit in a split pane or its own tab, in the directory of your currently focused pane
- Idempotent launcher: triggering again focuses / toggles the existing pane instead of stacking duplicates
- Press `C` to have an AI read your staged diff and propose 3 conventional-commit candidates — pick one to commit
- Press `B` to switch between AI CLI backends (claude / codex / opencode / gemini)

## Install

Requires herdr >= 0.7.0. lazygit is detected at install time and installed via Homebrew if missing.

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

The first two are custom commands added by this plugin; the rest are common lazygit defaults (press `?` inside lazygit for the full list):

| Key | Panel | Action |
| --- | --- | --- |
| `C` | Files | **AI commit message**: reads the staged diff, pops a candidate menu, Enter commits (overrides the files panel's default "commit using git editor") |
| `B` | Global* | **Switch AI backend**: lists detected AI CLIs, select to activate |
| `Space` | Files | Stage / unstage the selected file |
| `d` | Files | Discard changes to the selected file |
| `o` | Files | Open file with the OS default app |
| `e` | Files | Open file in your editor |
| `f` | Files | Fetch |
| `p` | Global | Pull |
| `P` | Global | Push |
| `z` | Global | Undo the last operation (reflog-based) |
| `?` | Global | Open the keybinding help menu |

\* One caveat about `B` being "global": in lazygit, **panel-level default keybindings take precedence over global custom commands**. In the commits panel, `B` triggers lazygit's default "mark commit as rebase base" (which has real side effects — the commit rows gain ↑↑↑ markers; press `B` again and choose Reset to undo) instead of the AI backend menu. Use `B` from the files panel or any panel without a conflicting default. Likewise, `C` overrides the files panel's default "commit using git editor"; rebind it in your user override layer if you still need that.

### Using `C` (AI commit)

- Stage the files you want to commit with `Space` first, then press `C`.
- The candidate menu calls the AI CLI before it opens — expect a few seconds.
- With nothing staged, no usable backend, or a generation timeout, the menu shows a hint line starting with `(`; selecting such a line does **not** commit — it just echoes the hint to the command log, so pressing Enter to dismiss it is safe.
- Generated messages are single-line, English, conventional-commit style (`feat:` / `fix:` / `chore:` …).

## AI backend configuration

The `C` command relies on any one of these installed AI CLIs: `claude`, `codex`, `opencode`, `gemini`.

- Default mode is `auto`: the first available backend wins, probed in the order `claude > codex > opencode > gemini`.
- Press `B` inside lazygit to see each backend's status (`detected` / `missing` / `current`) and switch. `detected` only means the CLI is installed — not that it is logged in or eligible; on generation failure the hint line includes the backend name and a one-line stderr summary (e.g. gemini's `IneligibleTierError`) so you can fix the login or switch with `B`.
- The choice persists in `$HERDR_PLUGIN_CONFIG_DIR/ai-backend.conf` (shell-sourceable), which you can also edit by hand:

```sh
# auto | claude | codex | opencode | gemini | custom
AI_BACKEND=auto

# Used when AI_BACKEND=custom: the command reads prompt+diff on stdin, prints the message to stdout
AI_CUSTOM_CMD=""
```

## Customizing lazygit

The plugin loads two config layers via `LG_CONFIG_FILE` (the latter overrides the former):

1. The bundled base layer `lazygit-config.yml` (do not edit — plugin updates overwrite it)
2. Your override layer `$HERDR_PLUGIN_CONFIG_DIR/lazygit-user.yml` (created on first run; put your personal settings here)

The base layer is deliberately minimal: mouse support on, random tips off, the `C` / `B` custom commands, and nothing else — it also doesn't assume a Nerd Font (set `gui.nerdFontsVersion: "3"` in your override layer if you have one). Remember that `C` overrides the files panel's default "commit using git editor", and `B` is shadowed in panels that bind it by default (like commits) — see the key reference above.

## Layout

```
herdr-plugin.toml            # plugin manifest
lazygit-config.yml           # bundled lazygit config (customCommands live here)
scripts/
  ensure-lazygit.sh          # detect/install lazygit at plugin install time
  run-lazygit.sh             # pane entrypoint: assemble config, exec lazygit
  open-lazygit.sh            # action: open in a split (idempotent open/focus/toggle)
  open-lazygit-tab.sh        # action: open in a tab
  ai-commit-msg.sh           # AI commit message generation / backend management
```
