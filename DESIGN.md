# DESIGN — Unified Design Principles for herdr-lazygit

> This document is the plugin's "constitution": consult it before adding features, changing keybindings, or modifying the configuration structure.
> If the implementation conflicts with this document, this document takes precedence. To overturn a decision here, update this document before changing the code.

## 1. The Three-Verb Model

Users only need to remember three verbs in lazygit. Everything else uses native lazygit keybindings, which the plugin does not claim:

| Verb | Default key | context | handler | Meaning |
| --- | --- | --- | --- | --- |
| **Commit** | `C` | `files` | `open-ai-commit-pane.sh` | Open the GitCommit pane immediately: show generation progress → select/edit a message → commit |
| **Expand** | `U` (the variable remains `KEY_ZOOM` for compatibility with old configurations) | `global` | `toggle-expand.sh` | Toggle lazygit itself between the sidebar and expanded layouts |
| **Settings** | `;` (candidates: `<c-s>` > O > `;` > `,`; see Appendix A for the analysis) | `global` | `open-settings-pane.sh` | Change all plugin behavior: AI backend/model/prompt, the three verb keybindings, and pane widths |

Design implications (why the old B/m/E/v/V bindings and object-level Zoom were all removed):

- `B` (switch backend), `m` (choose model), and `E` (edit prompt) are all fundamentally the **Settings verb** masquerading as top-level keys.
  They consume scarce keybinding space and can be shadowed by built-in panel bindings (`B` already caused trouble in the commits panel).
  They now all live on the settings page.
- `v`/`V` go back to lazygit (`v` = range select, `V` = paste cherry-picked commits). The `KEY_ZOOM` variable name remains for compatibility with existing `keys.conf` files, while the user-facing concept becomes **Expand**.
- The old Zoom pane is retired. Expanded lazygit already provides native diff, commit, and stash browsing plus every native action, covering the need to "show the selected item alongside the workspace." There is no longer a need to maintain three object templates and a separate pager lifecycle.

Moving Commit to a dedicated pane is not a visual preference; it fixes the feedback model. `menuFromCommand` runs the AI command synchronously before displaying its menu, so lazygit provides no progress UI during the 5–10 seconds required for generation. The GitCommit pane appears first and then starts generation in the background, immediately showing the backend/model, a spinner, and Ctrl-C. When generation finishes, the same fzf input can select a candidate, edit one, or accept a message written from scratch.

For every new feature, ask first: which verb does it belong to? If it belongs to none of them, it probably should not be built (see Section 6).

## 2. Division of Responsibilities: lazygit = Git Interface, herdr = Window System

| | lazygit is responsible for | herdr is responsible for |
| --- | --- | --- |
| What it owns | Git status, diff/history/stash browsing, and native stage/commit/sync interactions | Pane geometry, AI commit UI, and the settings interface |
| External interface | `customCommands` + configuration hot reload on focus-in | `pane split/run/close/send-text` + direct socket access through `layout-helper.py` |
| What we consume | The Commit entry point in the files context and the global Expand / Settings entry points | `place-diff` / `set-width` / `set-region-width` (absolute column widths) |

There are two normal layouts, with their state stored in `panel.conf` as `LAYOUT_MODE`:

```
sidebar                                  expanded
┌──────────────────────┬────────┐        ┌──────────────┬──────────────────┐
│      workspace       │lazygit│   U    │  workspace   │ lazygit itself   │
│                      │42 cols │  ⇄     │              │ default 110 cols │
└──────────────────────┴────────┘        └──────────────┴──────────────────┘
```

- Sidebar mode forces `sidePanelWidth: 0.99`, squeezing lazygit panels 1–5 into a single column. Expanded mode restores `0.3333`, making the native main view and every native interaction visible again. Both modes fix `portraitMode: never` to prevent abrupt automatic layout changes in tall panes.
- `U` updates the state and regenerates the GUI configuration first, then calls `set-width`, and finally injects CSI focus-in into lazygit. This hot-reloads both the layout and keybindings within the same keypress.
- AI Commit / Settings remain temporary wide panes to the right of the sidebar. While one is visible, lazygit is temporarily set to `SIDEBAR_COLS`. Before it exits, it restores the sidebar/expanded width that was active when it opened; `exit` then closes the pane automatically.
- Only one pane of each type may exist at a time. Any existing pane is found by label and closed first: `GitCommit` / `GitSettings`.
- The `open` / `open-tab` launchers reuse only within the current workspace and only when the candidate pane's `foreground_cwd` (fallback `cwd`) resolves to the same git worktree as the launch target (`git rev-parse --show-toplevel` on both sides). Different repositories, different worktrees of the same repository, or any cwd/git-resolution failure all degrade to OPEN instead of reusing the wrong pane. If either side is not a git repo, the fallback identity is the directory path itself.
- Widths are configurable through `SIDEBAR_COLS` / `EXPAND_COLS` / `COMMIT_COLS` / `SETTINGS_COLS`.

In one sentence: **lazygit handles Git interactions; herdr decides how wide lazygit should be right now and where supporting UI should open.**

## 3. Non-Negotiable Keybinding Rules

There are three user-facing rules, with no exceptions:

1. **Plugin keybindings must not shadow commonly used built-in lazygit keys.**
2. **Any conflict means changing the key** (change the plugin key, not lazygit's key).
3. **Every plugin key can be remapped through the settings page** (persisted in `keys.conf`).

The source-level keybinding precedence that supports these rules is fixed and verified:

```
panel custom  >  panel built-in  >  global custom  >  global built-in
```

Therefore, a custom key with `context: 'global'` is shadowed by the same built-in key in **any panel**.
Example: pressing the global custom key `S` in the files panel opens the built-in stash menu instead of our command.
Global keys (KEY_ZOOM / KEY_SETTINGS) must therefore be unused across **all list panels**.

Resolved keybinding decisions:

- **`v` / `V` are returned entirely to lazygit** (`v` = range select, `V` = paste cherry-picked commits). The old bindings are removed.
- **`C` stays** in the files panel. It shadows the infrequently used "commit using git editor" action (`commitChangesWithEditor`), which closely matches its new meaning and has an acceptable cost. This is a documented edge case in what Rule 1 calls "commonly used." Users who still need the original action can change the Commit key on the settings page or remap the built-in action in the keybinding section of `lazygit-user.yml`.
- **The default KEY_ZOOM candidate order is Z > U > X** (the variable name remains for compatibility), subject to free-key analysis. The analysis found that Z is occupied by `universal.redo`, so **the final default is `U`** (unused in every panel; see Appendix A).
- **KEY_SETTINGS does not use S** (see the conflict above). Its candidate order is `<c-s>` > O > `;` > `,`, also subject to free-key analysis. Both `<c-s>` and O are occupied by built-in keys, so **the final default is `;`** (unused in every section; see Appendix A).

Free-key analysis is **machine work, not manual work**. `scripts/free-keys.py` parses the complete default keybinding section emitted by `lazygit --config` (all 167 remappable actions, cross-checked against the bundled `schema/config.json`) and prints a candidate-key × panel occupancy matrix. Its `check KEY context...` subcommand validates conflicts in real time for the generation layer and settings-page remapping. The conclusions are recorded in Appendix A.

## 4. Three-Layer Configuration Model

```
  ①  lazygit-config.yml            Bundled layer — included in the plugin repository
      (plugin root)                and overwritten by plugin updates. Contains only GUI
                                   settings that do not vary by mode; customCommands moved out.
            │
            │  LG_CONFIG_FILE merges from left to right
            ▼
  ②  generated.yml                 Generated layer — built by gen-config-layer.sh from
      ($HERDR_PLUGIN_CONFIG_DIR)    keys.conf and panel.conf; regenerated immediately after
                                   settings changes or layout toggles. Its header marks it as
                                   machine-generated; do not edit it.
            │
            ▼
  ③  lazygit-user.yml              User layer — handwritten and always last, so it always wins.
      ($HERDR_PLUGIN_CONFIG_DIR)    Put personal settings and built-in key remapping here.
```

Merge behavior (verified experimentally and essential to the layering model):

- For ordinary fields, later files override earlier files field by field.
- `customCommands` arrays are **appended across files**; for the same key + context, the later file wins (so the user layer can override a complete command from the generated layer).
- **A missing file is a fatal lazygit startup error.** Before constructing `LG_CONFIG_FILE`, `run-lazygit.sh` must therefore call `gen-config-layer.sh` (idempotent and millisecond-scale) to ensure that layers ② and ③ exist, and only then `exec lazygit`.

Configuration-file responsibilities (all files live in `$HERDR_PLUGIN_CONFIG_DIR`, falling back to `~/.config/herdr-lazygit`):

| File | Writer | Contents |
| --- | --- | --- |
| `keys.conf` | Settings page | **Only** the keys for the three verbs: `KEY_COMMIT` / `KEY_ZOOM` / `KEY_SETTINGS` (sourceable by the shell; missing = default). Built-in key remapping does **not** belong here; that belongs in the user-layer `lazygit-user.yml` |
| `panel.conf` | Settings page / Expand handler | `SIDEBAR_COLS` / `EXPAND_COLS` / `COMMIT_COLS` / `SETTINGS_COLS` / `LAYOUT_MODE` |
| `ai-backend.conf` | Settings page | `AI_BACKEND` / `AI_CUSTOM_CMD` / per-backend model settings |
| `prompt.txt` | Settings page (`$EDITOR`) | Custom prompt for AI commits |
| `generated.yml` | `gen-config-layer.sh` | Mode-specific GUI settings + the three verb customCommands; the header marker records both keys and layout |
| `lazygit-user.yml` | User | Any lazygit configuration; always wins |

## 5. Hot-Reload Model

On terminal **focus-in**, lazygit 0.63.0 stats all configuration files and fully hot-reloads them when an mtime has changed, including rebuilding its keybinding table through `resetKeybindings`. Verified in herdr: edit YAML externally, switch away, and switch back to the pane for the change to take effect without a restart. This is the settings page's entire activation mechanism — **the filesystem is the bus; there is no IPC, signal, or restart**:

```
Change a setting / press U to toggle the layout
  → write keys.conf / panel.conf / ai-backend.conf
  → immediately call gen-config-layer.sh to rewrite generated.yml
  → switch back to the lazygit pane, or let the U handler inject CSI focus-in
  → lazygit stats the changes and hot-reloads
  → new keybindings/configuration take effect
```

Two supporting conventions:

- The settings interface always displays the message "Changes apply automatically when you return to the lazygit pane (hot reload)" to set user expectations.
- `run-lazygit.sh` also runs the generator (idempotently) immediately before `exec`, ensuring cold starts and hot reloads see the same generated layer. There is one generation path and no competing source of truth.

## 6. Reproducible Runtime Packaging

The plugin treats lazygit and fzf as part of its tested runtime, not as mutable
system dependencies. A GitHub install runs `scripts/install-runtime.sh`, which
maps macOS/Linux and x86_64/ARM64 to pinned upstream release archives, verifies
repository-pinned SHA-256 digests, and writes both executables to the managed
plugin checkout's `bin/` directory. Runtime scripts resolve those files by
absolute path through `runtime-env.sh`; they never invoke a same-named binary
from the user's `PATH`.

This is deliberately different from package-manager bootstrapping:

- installation never invokes Homebrew, apt, dnf, pacman, or `sudo`;
- the same plugin version uses the same lazygit/fzf versions everywhere;
- key-conflict analysis and generated configuration target the binary that
  actually runs;
- reinstalling the plugin atomically replaces its managed checkout and runtime;
- `plugin link` remains a development operation and requires running
  `scripts/install-runtime.sh` manually because Herdr does not execute build
  commands for linked plugins.

The remaining host requirements are Herdr, Bash, Git, Python >= 3.7, standard
archive/hash utilities, and either curl or wget. Python is an explicit runtime
requirement because pane geometry, JSON handling, locking, timeout handling,
and key analysis use its standard library.

Two relief valves temper the private runtime for existing lazygit users. The
pane merges the user's own lazygit config file underneath the plugin's layers
(layer 0; `INHERIT_USER_CONFIG=0` in panel.conf opts out), so personal themes
and settings survive without weakening the plugin's ownership of the keys it
generates. And `RUNTIME_LAZYGIT_BIN` / `RUNTIME_FZF_BIN` in panel.conf
substitute explicit binaries — a deliberate, version-warned, unsupported
escape hatch, which is not the same thing as implicit PATH lookup: the paths
are absolute and chosen by the user. Launchers precheck the resolved runtime
before opening a pane and report failures through action stderr (visible in
`herdr plugin log list`); the pane entrypoint runs lazygit as a child rather
than exec'ing it, so a startup rejection (for example an inherited config key
unknown to the pinned version) leaves a readable error in the pane.

## 7. Strategic Boundaries and Stop Signals

**Out of scope** (unreachable through the lazygit approach and therefore fake integration):

- Hover interactions: lazygit has no hover event model.
- Custom mouse semantics (dragging, context menus, or clicking a row to trigger plugin logic): lazygit consumes mouse events internally, and `customCommands` cannot hook them.
- Drawing a custom commit graph or any graphical overlay on the canvas: we do not own lazygit's render loop.

**Stop signals** (if any one appears, stop immediately; do not seek a workaround):

1. A feature requires **capturing and parsing lazygit's screen contents** to obtain state. This is the clearest stop signal. Screen scraping is brittle fake integration that breaks when lazygit changes.
2. Data unavailable through SessionState templates. Template fields are the ceiling of plugin capability; request a missing field upstream instead of routing around it locally.
3. The feature requires a fork or patch of lazygit.
4. The settings page starts demanding persistence, a state machine, or a custom UI framework. It must remain an fzf menu loop; the AI commit pane likewise owns only one generation/edit/commit lifecycle.

The criterion in one sentence: **we consume only lazygit's official interfaces (customCommands templates, configuration files, and CLI output) and herdr's official interfaces (CLI and socket RPC). If either side requires an unofficial channel, that feature does not belong in this plugin.**

---

## Appendix A: Free-Key Analysis (lazygit 0.63.0, verified during the 2026-07 integration phase)

Data source: the complete default keybinding section printed by `lazygit --config` (185 lines / 11 sections), parsed by `scripts/free-keys.py` and cross-checked against the bundled `schema/config.json`.
The keybinding table changes between lazygit versions. After an upgrade, run `python3 scripts/free-keys.py` to reproduce the matrix below and update this appendix accordingly.

### Candidate-Key × Panel Occupancy Matrix

`-` = no built-in binding in that section. subCommits / reflogCommits share the `keybinding.commits` section with commits and are therefore included in the commits column.

| Key | universal | files | commits (including subCommits/reflogCommits) | stash | branches |
| --- | --- | --- | --- | --- | --- |
| `Z` | redo | - | - | - | - |
| `U` | - | - | - | - | - |
| `X` | - | - | - | - | - |
| `<c-s>` | confirmInEditor-alt, filteringMenu | - | - | - | - |
| `O` | - | - | - | - | viewPullRequestOptions |
| `;` | - | - | - | - | - |
| `,` | prevPage | - | - | - | - |
| `C` | - | commitChangesWithEditor | cherryPickCopy | - | - |
| `v` | toggleRangeSelect | - | - | - | - |
| `V` | - | - | pasteCommits | - | - |

### Conclusions

1. **The final default for KEY_ZOOM (now Expand) is `U`** (candidates Z > U > X, context: global):
   - `Z` ✗ — occupied by `universal.redo`. Although its Zoom meaning is the closest fit, Rule 1 takes priority, so Z is rejected.
   - `U` ✓ — unused in universal/files/commits/stash/branches, so U is selected.
   - `X` was not reached (it is also unused everywhere and remains a natural remapping option for users).
2. **The final default for KEY_SETTINGS is `;`** (candidates `<c-s>` > O > `;` > `,`):
   - `<c-s>` ✗ — occupied by `universal.filteringMenu` and `universal.confirmInEditor-alt`.
   - `O` ✗ — occupied by `branches.viewPullRequestOptions` (a global key must be unused in every panel; one occupied panel disqualifies it).
   - `;` ✓ — unused in every section, so it is selected.
   - `,` was not reached (it is occupied by `universal.prevPage` and would be rejected if reached).
3. **`C` stays**: it shadows only `files.commitChangesWithEditor` (an accepted exception; see Section 3 for the rationale). Although `commits.cherryPickCopy` also uses C, KEY_COMMIT is declared only in the `files` context, so it is unaffected.
4. **Implication for global keys**: panel-level built-ins with the same key shadow KEY_ZOOM / KEY_SETTINGS, so the settings page validates them using the global context. The defaults `U` / `;` are unused across all sections. The generated layer retains conditional `<disabled>` compatibility for handwritten KEY_SETTINGS configurations.
