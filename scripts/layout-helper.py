#!/usr/bin/env python3
"""Geometry helper for herdr-lazygit: absolute pane widths via layout.set_split_ratio.

herdr's `pane split --ratio` can only divide the target pane's own rectangle,
so a narrow sidebar can never be split into a wide diff pane directly. This
helper talks to the herdr socket (HERDR_SOCKET_PATH) and sets split ratios
absolutely, in columns, by walking the layout tree from `layout.export`.

Subcommands:
  set-width  <pane_id> <cols>
      Resize the nearest right-split ancestor so the subtree containing
      <pane_id> is exactly <cols> columns wide. Used to keep the lazygit
      sidebar narrow after opening it.
  place-diff <git_pane> <diff_pane> <git_cols> <diff_cols>
      After `pane split <git> --direction right` created <diff_pane>, expand
      the (git|diff) region to git_cols+diff_cols (taking space from the rest
      of the tab) and split it git_cols / diff_cols.
  set-region-width <git_pane> <cols>
      Shrink the region that contains <git_pane>'s parent split back to
      <cols>. Run just before the diff pane exits, so when it closes the
      sidebar is left at exactly <cols>.
"""
import json
import os
import socket
import subprocess
import sys


def rpc(method, params):
    s = socket.socket(socket.AF_UNIX)
    s.connect(os.environ["HERDR_SOCKET_PATH"])
    s.sendall((json.dumps({"id": "layout-helper", "method": method, "params": params}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    resp = json.loads(buf.decode())
    if "error" in resp:
        raise SystemExit(f"layout-helper: {method}: {resp['error']}")
    return resp["result"]


def cli(*args):
    herdr = os.environ.get("HERDR_BIN_PATH", "herdr")
    out = subprocess.run([herdr, *args], capture_output=True, text=True)
    return json.loads(out.stdout)["result"]


def load(pane_id):
    """Return (tree_root, {pane_id: rect}) for the tab containing pane_id."""
    lay = cli("pane", "layout", "--pane", pane_id)["layout"]
    rects = {p["pane_id"]: p["rect"] for p in lay["panes"]}
    tree = rpc("layout.export", {"tab_id": lay["tab_id"]})["layout"]["root"]
    return tree, rects


def find_path(node, pane_id, path=()):
    if node["type"] == "pane":
        return path if node["pane_id"] == pane_id else None
    return (find_path(node["first"], pane_id, path + (False,))
            or find_path(node["second"], pane_id, path + (True,)))


def node_at(tree, path):
    node = tree
    for second in path:
        node = node["second" if second else "first"]
    return node


def pane_ids(node):
    if node["type"] == "pane":
        return [node["pane_id"]]
    return pane_ids(node["first"]) + pane_ids(node["second"])


def subtree_width(node, rects):
    rs = [rects[p] for p in pane_ids(node) if p in rects]
    if not rs:
        return 0
    return max(r["x"] + r["width"] for r in rs) - min(r["x"] for r in rs)


def nearest_right_split(tree, path):
    """Deepest ancestor of `path` that is a right-split. Returns (split_path,
    is_second_child) for the child subtree lying on `path`, or None."""
    for depth in range(len(path) - 1, -1, -1):
        split = node_at(tree, path[:depth])
        if split["direction"] == "right":
            return path[:depth], path[depth]
    return None


def set_subtree_width(pane_id, tree, rects, path, cols):
    """Make the subtree on `path`'s side of its nearest right-split ancestor
    exactly `cols` wide."""
    hit = nearest_right_split(tree, path)
    if hit is None:
        return False  # pane spans the full tab width already
    split_path, is_second = hit
    split_w = subtree_width(node_at(tree, split_path), rects)
    if split_w <= 0 or cols >= split_w:
        return False
    ratio = 1 - cols / split_w if is_second else cols / split_w
    rpc("layout.set_split_ratio",
        {"pane_id": pane_id, "path": list(split_path), "ratio": ratio})
    return True


def main():
    cmd = sys.argv[1]

    if cmd == "set-width":
        pane, cols = sys.argv[2], int(sys.argv[3])
        tree, rects = load(pane)
        path = find_path(tree, pane)
        if path is None:
            raise SystemExit(f"layout-helper: pane {pane} not in layout")
        set_subtree_width(pane, tree, rects, path, cols)

    elif cmd == "place-diff":
        git, diff, git_cols, diff_cols = sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
        tree, rects = load(git)
        diff_path = find_path(tree, diff)
        if diff_path is None:
            raise SystemExit(f"layout-helper: pane {diff} not in layout")
        s_path = diff_path[:-1]           # the (git | diff) split
        region = node_at(tree, s_path)
        # 1. grow the region to git+diff columns (its parent yields the space);
        #    impossible when the region already spans the tab (sidebar in its
        #    own tab) — then the diff simply gets the remaining width
        grown = set_subtree_width(git, tree, rects, s_path, git_cols + diff_cols)
        region_w = (git_cols + diff_cols) if grown else subtree_width(region, rects)
        # 2. divide the region: git left, diff right
        rpc("layout.set_split_ratio",
            {"pane_id": git, "path": list(s_path),
             "ratio": min(git_cols / region_w, 0.9)})

    elif cmd == "set-region-width":
        git, cols = sys.argv[2], int(sys.argv[3])
        tree, rects = load(git)
        path = find_path(tree, git)
        if path is None or len(path) == 0:
            return
        # the region is the parent split of the git pane (git | diff)
        set_subtree_width(git, tree, rects, path[:-1], cols)

    else:
        raise SystemExit(f"layout-helper: unknown subcommand {cmd}")


if __name__ == "__main__":
    main()
