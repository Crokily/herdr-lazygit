#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""free-keys.py — lazygit free-key analysis, the data source used to choose
keys for the herdr-lazygit plugin.

Data source: the keybinding section of the default configuration printed by
`lazygit --config` (following the installed lazygit version rather than a
hard-coded key table). Uses only the standard library and includes a small
indentation-based parser for that output instead of PyYAML.

Usage:
  free-keys.py [report] [KEY ...]
      Print a candidate-key × panel occupancy matrix. With no KEY arguments,
      use the DECISIONS candidates (Z U X <c-s> O ';' ',' plus existing C v V)
      and report default-key conclusions for KEY_ZOOM / KEY_SETTINGS in
      candidate order.

  free-keys.py check KEY context [context ...]
      Check whether KEY is unused in the given customCommands contexts.
      Contexts use lazygit customCommands names (files / commits / subCommits /
      reflogCommits / stash / localBranches / global …).
      Output one line per conflict to stdout, separated by a TAB:
          <context>\t<section>.<action>
      Exit codes: 0 = all free; 1 = conflict; 2 = invalid arguments or unable
      to obtain the lazygit configuration.

Key-selection rule (user-approved; see DESIGN.md): plugin keys must not shadow
built-in lazygit keys. lazygit key precedence is panel custom > panel built-in >
global custom > global built-in, so "free" means that the key has no built-in
binding in either the target panel's keybinding section or the universal section
(the global context requires it to be unused in every section).

A known, explicitly accepted exception: default KEY_COMMIT C shadows the
infrequently used commitChangesWithEditor action in the files panel (documented
in DESIGN.md). Settings should therefore accept "new key == current key"
without running check again.

Analysis conclusions (lazygit 0.63.0, recorded in the DESIGN.md appendix):
  KEY_ZOOM (Expand/global): Z ✗ (universal.redo) → U ✓ (free in all panels) => default U
  KEY_SETTINGS: <c-s> ✗(universal.filteringMenu / confirmInEditor-alt)
               → O ✗(branches.viewPullRequestOptions)
               → ; ✓ (free in all panels)                    => default ;
"""

import re
import subprocess
import sys

# customCommands context name -> keybinding section name.
# subCommits / reflogCommits share keybinding.commits with commits; several
# branch-sidebar contexts share keybinding.branches.
CONTEXT_TO_SECTION = {
    "global": None,  # None = all sections
    "status": "status",
    "files": "files",
    "worktrees": "worktrees",
    "localBranches": "branches",
    "remoteBranches": "branches",
    "remotes": "branches",
    "tags": "branches",
    "branches": "branches",
    "commits": "commits",
    "subCommits": "commits",
    "reflogCommits": "commits",
    "commitFiles": "commitFiles",
    "stash": "stash",
    "submodules": "submodules",
}

# Panel columns shown in the report matrix (universal always participates).
REPORT_SECTIONS = ["universal", "files", "commits", "stash", "branches"]

# DECISIONS candidates (default input in report mode).
ZOOM_CANDIDATES = ["Z", "U", "X"]
SETTINGS_CANDIDATES = ["<c-s>", "O", ";", ","]
EXTRA_REPORT_KEYS = ["C", "v", "V"]


def norm_key(raw):
    """Normalize a key name into a comparable form.

    - Preserve an unquoted single-character key as-is (case-sensitive).
    - For angle-bracket keys such as <c-s> / <ctrl+s> / <alt-down>: lowercase,
      split on -/+, normalize modifier aliases (c->ctrl, a->alt, m->alt), sort
      modifiers, and join them with +.
    """
    k = raw.strip()
    if len(k) >= 2 and k[0] == k[-1] and k[0] in ("'", '"'):
        k = k[1:-1]
    if not (k.startswith("<") and k.endswith(">") and len(k) > 2):
        return k
    inner = k[1:-1].lower()
    parts = [p for p in re.split(r"[-+]", inner) if p != ""]
    if not parts:  # The key itself is '-' or '+' (not in defaults; defensive).
        return "<" + inner + ">"
    alias = {"c": "ctrl", "a": "alt", "m": "alt", "opt": "alt", "option": "alt"}
    mods = [alias.get(p, p) for p in parts[:-1]]
    key = parts[-1]
    return "<" + "+".join(sorted(mods) + [key]) + ">"


def load_bindings():
    """Run lazygit --config and parse its keybinding section.

    Return {section: {action: [norm_key, ...]}}. The parser targets only the
    shape of this output: four spaces per indentation level, `action: value`,
    flow lists [a, b], and block lists with `- item`.
    """
    try:
        out = subprocess.run(
            ["lazygit", "--config"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        sys.stderr.write("free-keys.py: unable to run `lazygit --config` (%s); "
                         "run scripts/ensure-lazygit.sh first\n" % e)
        sys.exit(2)

    sections = {}
    in_kb = False
    section = None
    action = None  # Action whose block list is currently being collected.
    for line in out.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        stripped = line.strip()
        if indent == 0:
            in_kb = (stripped == "keybinding:")
            section = action = None
            continue
        if not in_kb:
            continue
        if indent == 4 and stripped.endswith(":"):
            section = stripped[:-1]
            sections[section] = {}
            action = None
        elif indent == 8 and section is not None:
            if stripped.endswith(":"):           # Block-list start, e.g. jumpToBlock:
                action = stripped[:-1]
                sections[section][action] = []
            else:
                name, _, value = stripped.partition(":")
                value = value.strip()
                action = None
                if value.startswith("[") and value.endswith("]"):
                    keys = [norm_key(v) for v in value[1:-1].split(",") if v.strip()]
                else:
                    keys = [norm_key(value)]
                sections[section][name.strip()] = keys
        elif indent > 8 and stripped.startswith("- ") and action and section:
            sections[section][action].append(norm_key(stripped[2:]))
    if "universal" not in sections:
        sys.stderr.write("free-keys.py: could not parse keybinding.universal "
                         "from `lazygit --config`; the output format may have changed\n")
        sys.exit(2)
    return sections


def occupants(bindings, key, section):
    """Return [(section, action)] built-ins for key in one section (missing = empty)."""
    nk = norm_key(key)
    found = []
    for act, keys in bindings.get(section, {}).items():
        if nk in keys:
            found.append((section, act))
    return found


def sections_for_context(bindings, ctx):
    """Map context to keybinding sections to check (always includes universal)."""
    if ctx == "global":
        return list(bindings.keys())
    sec = CONTEXT_TO_SECTION.get(ctx)
    if sec is None:
        sys.stderr.write("free-keys.py: unknown context '%s' (available: %s)\n"
                         % (ctx, " ".join(sorted(CONTEXT_TO_SECTION))))
        sys.exit(2)
    out = ["universal"]
    if sec != "universal" and sec in bindings:
        out.append(sec)
    return out


def cmd_check(argv):
    if len(argv) < 2:
        sys.stderr.write("Usage: free-keys.py check KEY context [context ...]\n")
        sys.exit(2)
    key, contexts = argv[0], argv[1:]
    bindings = load_bindings()
    conflict = False
    for ctx in contexts:
        seen = set()
        for sec in sections_for_context(bindings, ctx):
            for s, act in occupants(bindings, key, sec):
                if (s, act) in seen:
                    continue
                seen.add((s, act))
                conflict = True
                print("%s\t%s.%s" % (ctx, s, act))
    sys.exit(1 if conflict else 0)


def first_free(bindings, candidates, contexts):
    """Find the first candidate free in all contexts; return (key, rejection notes)."""
    notes = []
    for cand in candidates:
        occupied = []
        for ctx in contexts:
            for sec in sections_for_context(bindings, ctx):
                occupied += occupants(bindings, cand, sec)
        if occupied:
            uniq = sorted(set("%s.%s" % (s, a) for s, a in occupied))
            notes.append("%s ✗ (%s)" % (cand, ", ".join(uniq)))
        else:
            notes.append("%s ✓" % cand)
            return cand, notes
    return None, notes


def cmd_report(keys):
    bindings = load_bindings()
    if not keys:
        keys = []
        for k in ZOOM_CANDIDATES + SETTINGS_CANDIDATES + EXTRA_REPORT_KEYS:
            if k not in keys:
                keys.append(k)

    width = max(len(k) for k in keys) + 2
    header = "Key".ljust(width)
    for sec in REPORT_SECTIONS:
        header += sec.ljust(14)
    print(header)
    print("-" * len(header))
    for k in keys:
        row = k.ljust(width)
        for sec in REPORT_SECTIONS:
            occ = occupants(bindings, k, sec)
            cell = ",".join(a for _, a in occ) if occ else "-"
            row += (cell[:12] + ("…" if len(cell) > 12 else "")).ljust(14)
        print(row)
    print()

    zoom_ctx = ["global"]
    zoom, zoom_notes = first_free(bindings, ZOOM_CANDIDATES, zoom_ctx)
    setk, set_notes = first_free(bindings, SETTINGS_CANDIDATES, ["global"])
    print("KEY_ZOOM candidates (context: %s):" % " ".join(zoom_ctx))
    for n in zoom_notes:
        print("  " + n)
    print("KEY_SETTINGS candidates (context: global):")
    for n in set_notes:
        print("  " + n)
    print()
    print("Conclusion: KEY_ZOOM=%s  KEY_SETTINGS=%s" % (zoom or "no available candidate!", setk or "no available candidate!"))


def main():
    argv = sys.argv[1:]
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    if argv and argv[0] == "check":
        cmd_check(argv[1:])
    elif argv and argv[0] == "report":
        cmd_report(argv[1:])
    else:
        cmd_report(argv)


if __name__ == "__main__":
    main()
