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

There are two normal layouts. Their state is pane-local: `run-lazygit.sh` creates a dedicated `layout-<pid>-<epoch>.yml` layer for each lazygit pane, seeded from the launcher's explicit initial mode, and `toggle-expand.sh` rewrites only that file. New splits default to `sidebar`; new tabs default to `expanded`. `DEFAULT_MODE_SPLIT` and `DEFAULT_MODE_TAB` in `panel.conf` override those defaults independently. Invalid values warn and use the corresponding built-in default. These preferences affect new panes only; reusing a pane preserves its mode and placement. An expanded split uses the same bounded width as Expand; a single-pane tab retains its full width.

```
sidebar                                  expanded
┌──────────────────────┬────────┐        ┌──────────────┬──────────────────┐
│      workspace       │lazygit│   U    │  workspace   │ lazygit itself   │
│                      │42 cols │  ⇄     │              │ default 110 cols │
└──────────────────────┴────────┘        └──────────────┴──────────────────┘
```

- Sidebar mode forces `sidePanelWidth: 0.99`, squeezing lazygit panels 1–5 into a single column. Expanded mode restores `0.3333`, making the native main view and every native interaction visible again. Both modes fix `portraitMode: never` to prevent abrupt automatic layout changes in tall panes.
- `U` rewrites the pane-local layout layer first, then calls `set-width`, and finally injects CSI focus-out followed by focus-in into lazygit. An already-focused lazygit ignores a repeated focus-in; the pair forces a real transition and configuration reload without changing another pane's layout state.
- AI Commit / Settings remain temporary wide panes to the right of the sidebar. While one is visible, lazygit is temporarily set to `SIDEBAR_COLS`. Before it exits, it restores the sidebar/expanded width that was active when it opened; `exit` then closes the pane automatically.
- Only one pane of each type may exist at a time. Any existing pane is found by label and closed first: `GitCommit` / `GitSettings`.
- The `open` / `open-tab` launchers reuse only within the invoking workspace and only when the candidate pane's `foreground_cwd` (fallback `cwd`) resolves to the same git worktree as the launch target (`git rev-parse --show-toplevel` on both sides). Different repositories, different worktrees of the same repository, or unresolvable candidate paths are not reused. Non-git directories use their directory identity. Failed Herdr queries, malformed responses, and command timeouts fail visibly rather than being mistaken for an absent pane. A failed mutation is never retried automatically: a timeout may mean the server already applied it.
- Launcher context is captured once from `HERDR_PLUGIN_CONTEXT_JSON`; split creation names the source pane and tab creation names the workspace. When no action context is supplied (manual invocation), query the current pane once. Never replace an explicit source with a later UI focus. A vanished source fails instead of opening elsewhere.
- Herdr 0.9's public plugin open/focus handlers update server focus but omit the client-view projection performed by ordinary `tab.focus`. After creating a tab, explicitly focus the tab ID from the creation response; cross-tab reuse first selects the exact plugin pane, then focuses its tab. Keep explicit workspace targeting and never retry a failed creation. `tab.focus` has session-wide semantics on 0.9, so this compatibility step can change every attached client's view. The plugin's action context has no originating client ID; strictly client-local tab switching requires an upstream API extension. Validate actual client rendering, not `focused=true` alone.
- A shared launcher helper owns a non-inheritable OS lock per user/server/workspace, from state inspection through the final mutation and initial sizing. Both actions share that lock; unrelated servers/workspaces do not. Commands have individual and overall deadlines; timeout cleanup targets only the command's process group. Errors go to action stderr and a bounded, best-effort Herdr notification. Lock files are stable coordination points and are not removed to recover from contention.
- Widths are configurable through `SIDEBAR_COLS` / `EXPAND_COLS` / `COMMIT_COLS` / `SETTINGS_COLS`.
- Herdr 0.7.0 lacks `layout.set_split_ratio`. Only an explicit unknown-method rejection enables the `pane.resize` compatibility path: select a pane on the correct split boundary and apply a bounded ratio delta without changing focus or recreating terminals. `layout.apply` must never be used for resizing because it replaces the target tab's terminals. All versions retain Herdr's own ratio limits.

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

## 4. Layered Configuration Model

```
  ①  lazygit-config.yml            Bundled layer — included in the plugin repository
      (plugin root)                and overwritten by plugin updates. Contains only GUI
                                   settings that do not vary by mode; customCommands moved out.
            │
            │  LG_CONFIG_FILE merges from left to right
            ▼
  ②  generated.yml                 Generated layer — built by gen-config-layer.sh from
      ($HERDR_PLUGIN_CONFIG_DIR)    keys.conf; regenerated after settings changes that affect
                                   plugin-owned keys/customCommands. Its header marks it as
                                   machine-generated; do not edit it.
            │
            ▼
  ③  layout-<pid>-<epoch>.yml      Per-pane layout layer — created by run-lazygit.sh and
      ($HERDR_PLUGIN_CONFIG_DIR)    rewritten by toggle-expand.sh. Stores only this pane's
                                   layout-dependent GUI settings.
            │
            ▼
  ④  lazygit-user.yml              User layer — handwritten and always last, so it always wins.
      ($HERDR_PLUGIN_CONFIG_DIR)    Put personal settings and built-in key remapping here.
```

Merge behavior (verified experimentally and essential to the layering model):

- For ordinary fields, later files override earlier files field by field.
- `customCommands` arrays are **appended across files**; for the same key + context, the later file wins (so the user layer can override a complete command from the generated layer).
- **A missing file is a fatal lazygit startup error.** Before constructing `LG_CONFIG_FILE`, `run-lazygit.sh` must therefore call `gen-config-layer.sh` and create both the per-pane layout layer and `lazygit-user.yml`, and only then start lazygit.

Configuration-file responsibilities (all files live in `$HERDR_PLUGIN_CONFIG_DIR`, falling back to `~/.config/herdr-lazygit`):

| File | Writer | Contents |
| --- | --- | --- |
| `keys.conf` | Settings page | **Only** the keys for the three verbs: `KEY_COMMIT` / `KEY_ZOOM` / `KEY_SETTINGS` (sourceable by the shell; missing = default). Built-in key remapping does **not** belong here; that belongs in the user-layer `lazygit-user.yml` |
| `panel.conf` | Settings page / user by hand | Global preferences only: `DEFAULT_MODE_SPLIT` / `DEFAULT_MODE_TAB` / `SIDEBAR_COLS` / `EXPAND_COLS` / `COMMIT_COLS` / `SETTINGS_COLS` / `INHERIT_USER_CONFIG` / `RUNTIME_*_BIN` |
| `ai-backend.conf` | Settings page | `AI_BACKEND` / `AI_CUSTOM_CMD` / per-backend model settings |
| `prompt.txt` | Settings page (`$EDITOR`) | Custom prompt for AI commits |
| `generated.yml` | `gen-config-layer.sh` | Global plugin layer: the three verb customCommands with no native key disables; header markers record requested and effective keys |
| `layout-<pid>-<epoch>.yml` | `run-lazygit.sh` / `toggle-expand.sh` | Pane-local GUI settings: `sidePanelWidth`, `expandFocusedSidePanel`, `portraitMode`, plus a header marker for `sidebar` vs `expanded` |
| `lazygit-user.yml` | User | Any lazygit configuration; always wins |

## 5. Hot-Reload Model

On a terminal **focus-out → focus-in transition**, lazygit stats all configuration files and fully hot-reloads them when an mtime has changed, including rebuilding its keybinding table through `resetKeybindings`. Repeating focus-in while already focused does not guarantee a reload. Edit YAML externally, switch away, and switch back to the pane for changes to take effect without a restart. The settings page uses this activation mechanism:

```
Change a setting
  → write keys.conf / panel.conf / ai-backend.conf as needed
  → immediately call gen-config-layer.sh when the generated global layer changes
  → switch back to the lazygit pane
  → lazygit stats the changes and hot-reloads
  → new keybindings/configuration take effect

Press U to toggle the layout
  → rewrite only this pane's layout-<pid>-<epoch>.yml
  → call set-width on the current herdr pane
  → inject CSI focus-out followed by focus-in into lazygit
  → lazygit stats the changed layout file and hot-reloads
  → the current pane switches layout; other panes do not
```

Two supporting conventions:

- The settings interface explains that key changes apply on return and initial-layout preferences apply to new panes only.
- `run-lazygit.sh` also runs the generator (idempotently) and seeds a fresh per-pane layout layer before starting lazygit, ensuring cold starts and hot reloads see the same global command layer. Initial-layout preferences apply only to newly created panes; changes to those preferences do not reset running panes.

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

## Appendix A: Free-Key Analysis (lazygit 0.65.0, verified 2026-09-13)

Data source: the pinned runtime's complete `lazygit --config` output, parsed by `scripts/free-keys.py`: 167 remappable actions across 11 sections. The candidate matrix below was reproduced with the downloaded 0.65.0 Linux ARM64 binary.
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
4. **Implication for global keys**: panel-level built-ins with the same key shadow KEY_ZOOM / KEY_SETTINGS, so the settings page validates them using the global context. The defaults `U` / `;` are unused across all sections. The generator checks all three effective plugin keys, including conflicts between plugin actions. Conflicting handwritten preferences fall back to a free plugin key with a warning; native bindings and `keys.conf` are preserved. Settings displays effective keys separately from saved preferences.
