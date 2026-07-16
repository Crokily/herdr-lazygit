#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""free-keys.py — lazygit 空闲键分析(herdr-lazygit 插件选键的数据源)。

数据源:`lazygit --config` 打印的默认配置里的 keybinding 段(随机器上安装的
lazygit 版本走,不硬编码键表)。只用标准库,自带一个针对该输出的小型缩进
解析器(不引 PyYAML)。

用法:
  free-keys.py [report] [KEY ...]
      打印候选键 × 面板 的占用矩阵。不给 KEY 时用 DECISIONS 里的候选集
      (Z U X <c-s> O ';' ',' 以及现有的 C v V),并按候选顺序给出
      KEY_ZOOM / KEY_SETTINGS 的默认键结论。

  free-keys.py check KEY context [context ...]
      校验 KEY 在给定 customCommands context 里是否空闲。
      context 取 lazygit customCommands 的 context 名(files / commits /
      subCommits / reflogCommits / stash / localBranches / global …)。
      每个冲突输出一行(stdout,TAB 分隔):
          <context>\t<section>.<action>
      退出码:0 = 全部空闲;1 = 有冲突;2 = 参数错误 / 拿不到 lazygit 配置。

选键规则(用户拍板,见 DESIGN.md):插件键不得遮蔽 lazygit 内置键。
lazygit 按键优先级为 同面板 custom > 同面板内置 > global custom > global 内置,
所以"空闲"的定义是:该键在目标面板的 keybinding 段和 universal 段都没有
内置绑定(global context 则要求所有段全空)。

已知的、被明确接受的例外:KEY_COMMIT 默认 C 遮蔽 files 面板低频的
commitChangesWithEditor(记录于 DESIGN.md)。因此设置页在"新键 == 当前键"
时应直接接受,不必再过 check。

分析结论(lazygit 0.63.0,写入 DESIGN.md 附录):
  KEY_ZOOM(Expand/global): Z ✗(universal.redo)→ U ✓(全面板空闲) => 默认 U
  KEY_SETTINGS: <c-s> ✗(universal.filteringMenu / confirmInEditor-alt)
               → O ✗(branches.viewPullRequestOptions)
               → ; ✓(全面板空闲)                          => 默认 ;
"""

import re
import subprocess
import sys

# customCommands 的 context 名 -> keybinding 段名。
# subCommits / reflogCommits 与 commits 共用 keybinding.commits;
# 分支侧栏的若干 context 共用 keybinding.branches。
CONTEXT_TO_SECTION = {
    "global": None,  # None = 所有段
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

# 报告矩阵里展示的面板列(universal 永远参与判定)
REPORT_SECTIONS = ["universal", "files", "commits", "stash", "branches"]

# DECISIONS 里的候选键(报告模式的默认输入)
ZOOM_CANDIDATES = ["Z", "U", "X"]
SETTINGS_CANDIDATES = ["<c-s>", "O", ";", ","]
EXTRA_REPORT_KEYS = ["C", "v", "V"]


def norm_key(raw):
    """把键名归一成可比较的形式。

    - 去引号后的单字符键原样保留(大小写敏感)
    - <c-s> / <ctrl+s> / <alt-down> 等尖括号键:小写、按 -/+ 拆分,
      修饰符别名归一(c->ctrl, a->alt, m->alt),修饰符排序后用 + 连接
    """
    k = raw.strip()
    if len(k) >= 2 and k[0] == k[-1] and k[0] in ("'", '"'):
        k = k[1:-1]
    if not (k.startswith("<") and k.endswith(">") and len(k) > 2):
        return k
    inner = k[1:-1].lower()
    parts = [p for p in re.split(r"[-+]", inner) if p != ""]
    if not parts:  # 键本身是 '-' 或 '+' 之类(默认表里没有,防御)
        return "<" + inner + ">"
    alias = {"c": "ctrl", "a": "alt", "m": "alt", "opt": "alt", "option": "alt"}
    mods = [alias.get(p, p) for p in parts[:-1]]
    key = parts[-1]
    return "<" + "+".join(sorted(mods) + [key]) + ">"


def load_bindings():
    """跑 lazygit --config,解析 keybinding 段。

    返回 {section: {action: [norm_key, ...]}}。解析器只针对该输出的形状:
    4 空格一级缩进、`action: value`、flow 列表 [a, b]、块列表 `- item`。
    """
    try:
        out = subprocess.run(
            ["lazygit", "--config"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        sys.stderr.write("free-keys.py: 无法执行 `lazygit --config`(%s);"
                         "请先运行 scripts/ensure-lazygit.sh\n" % e)
        sys.exit(2)

    sections = {}
    in_kb = False
    section = None
    action = None  # 正在收集块列表的 action
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
            if stripped.endswith(":"):           # 块列表开头,如 jumpToBlock:
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
        sys.stderr.write("free-keys.py: 未能从 lazygit --config 解析出 "
                         "keybinding.universal 段,lazygit 输出格式可能已变化\n")
        sys.exit(2)
    return sections


def occupants(bindings, key, section):
    """返回 [(section, action)]:key 在指定段里的内置绑定(段不存在=空)。"""
    nk = norm_key(key)
    found = []
    for act, keys in bindings.get(section, {}).items():
        if nk in keys:
            found.append((section, act))
    return found


def sections_for_context(bindings, ctx):
    """context -> 需要检查的 keybinding 段列表(总是含 universal)。"""
    if ctx == "global":
        return list(bindings.keys())
    sec = CONTEXT_TO_SECTION.get(ctx)
    if sec is None:
        sys.stderr.write("free-keys.py: 未知 context '%s'(可用:%s)\n"
                         % (ctx, " ".join(sorted(CONTEXT_TO_SECTION))))
        sys.exit(2)
    out = ["universal"]
    if sec != "universal" and sec in bindings:
        out.append(sec)
    return out


def cmd_check(argv):
    if len(argv) < 2:
        sys.stderr.write("用法: free-keys.py check KEY context [context ...]\n")
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
    """按候选顺序找第一个在所有 contexts 空闲的键;返回 (key, 淘汰说明列表)。"""
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
    header = "键".ljust(width)
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
    print("KEY_ZOOM 候选(context: %s):" % " ".join(zoom_ctx))
    for n in zoom_notes:
        print("  " + n)
    print("KEY_SETTINGS 候选(context: global):")
    for n in set_notes:
        print("  " + n)
    print()
    print("结论: KEY_ZOOM=%s  KEY_SETTINGS=%s" % (zoom or "无可用候选!", setk or "无可用候选!"))


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
