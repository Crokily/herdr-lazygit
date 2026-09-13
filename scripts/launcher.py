#!/usr/bin/env python3
"""Shared split/tab launcher. Python >= 3.7; no third-party dependencies.

The parent owns the lock. Every child has closed extra descriptors and a
deadline. Action context, rather than a subsequent UI focus, selects targets.
"""
import contextlib
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time

from process_helper import run_command

SAFE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9:_-]*\Z")
SCRIPT_DIR = Path(__file__).resolve().parent
COMMAND_TIMEOUT = 3.0
LOCK_TIMEOUT = 2.0
TOTAL_TIMEOUT = 10.0


class LaunchError(Exception):
    pass


def pane_id(value):
    if not isinstance(value, str) or not SAFE_ID.fullmatch(value):
        raise LaunchError("invalid or missing pane/workspace/tab ID")
    return value


def normalize_dir(path):
    if not isinstance(path, str) or not path:
        return None
    resolved = os.path.realpath(path)
    return resolved if os.path.isdir(resolved) else None


class Launcher:
    def __init__(self, placement):
        self.placement = placement
        self.herdr = os.environ.get("HERDR_BIN_PATH") or "herdr"
        self.started = time.monotonic()
        self.deadline = self.started + TOTAL_TIMEOUT
        self.stage = "configuration"
        self.origin = {}
        self.target_dir = ""
        self.identity_cache = {}

    def command(self, argv, stage, check=True):
        self.stage = stage
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise LaunchError("launcher time limit reached")
        try:
            result = run_command(argv, min(COMMAND_TIMEOUT, remaining))
        except subprocess.TimeoutExpired:
            raise LaunchError("command timed out; its result may be unknown") from None
        except OSError as error:
            raise LaunchError(str(error)) from None
        if check and result.returncode:
            detail = result.stderr.strip() or result.stdout.strip() or "no error details"
            raise LaunchError("command exited {}: {}".format(result.returncode, detail[:1000]))
        return result

    def rpc(self, *args):
        result = self.command([self.herdr, *args], " ".join(args[:3]))
        try:
            response = json.loads(result.stdout)
            if response.get("error"):
                raise LaunchError(str(response["error"]))
            value = response["result"]
            if not isinstance(value, dict):
                raise ValueError("result must be an object")
            return value
        except (ValueError, KeyError, AttributeError, TypeError):
            raise LaunchError("Herdr returned an invalid response") from None

    def configure(self):
        # Snapshot before any slow operation. Full Herdr action contexts have
        # all three IDs; partial contexts with IDs are rejected, not retargeted.
        raw = os.environ.get("HERDR_PLUGIN_CONTEXT_JSON") or "{}"
        try:
            context = json.loads(raw)
            if not isinstance(context, dict):
                raise ValueError()
        except ValueError:
            raise LaunchError("invalid HERDR_PLUGIN_CONTEXT_JSON") from None
        self.context = context
        config = self.command(
            ["bash", str(SCRIPT_DIR / "launcher-config.sh"), self.placement],
            "runtime/config precheck",
        )
        if config.stderr:
            sys.stderr.write(config.stderr)
        try:
            self.mode, cols, end = config.stdout.split("\0")
            self.cols = int(cols)
            if end or self.mode not in ("sidebar", "expanded") or not 20 <= self.cols <= 500:
                raise ValueError()
        except ValueError:
            raise LaunchError("invalid launch preferences") from None

        ids = ("workspace_id", "tab_id", "focused_pane_id")
        if any(context.get(key) for key in ids):
            self.origin = {"workspace_id": pane_id(context.get("workspace_id")),
                           "tab_id": pane_id(context.get("tab_id")),
                           "pane_id": pane_id(context.get("focused_pane_id"))}
        else:
            current = self.rpc("pane", "current").get("pane", {})
            if not isinstance(current, dict):
                raise LaunchError("Herdr returned an invalid current pane")
            self.origin = {key: pane_id(current.get(key))
                           for key in ("workspace_id", "tab_id", "pane_id")}
            context = dict(current, **context)
        target = (context.get("focused_pane_cwd") or context.get("foreground_cwd")
                  or context.get("cwd") or context.get("workspace_cwd")
                  or os.path.expanduser("~"))
        self.target_dir = normalize_dir(target)
        if not self.target_dir:
            raise LaunchError("the launch directory no longer exists: {}".format(target))

    @contextlib.contextmanager
    def lock(self):
        self.stage = "launcher lock"
        config_dir = os.environ.get("HERDR_PLUGIN_CONFIG_DIR") or os.path.join(
            os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
            "herdr-lazygit")
        state_dir = Path(os.environ.get("HERDR_PLUGIN_STATE_DIR") or
                         os.path.join(config_dir, "state"))
        lock_dir = state_dir / "launcher-locks"
        lock_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        socket_path = os.environ.get("HERDR_SOCKET_PATH")
        endpoint = os.path.realpath(socket_path) if socket_path else json.dumps([
            os.environ.get("HERDR_CONFIG_PATH", "default-config"),
            os.environ.get("HERDR_SESSION", "default-session")])
        scope = json.dumps([os.getuid(), endpoint, self.origin["workspace_id"]])
        key = hashlib.sha256(scope.encode()).hexdigest()[:24]
        fd = os.open(str(lock_dir / (key + ".lock")),
                     os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise LaunchError("launcher lock is not an owned regular file")
            os.set_inheritable(fd, False)
            until = min(self.deadline, time.monotonic() + LOCK_TIMEOUT)
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as error:
                    if error.errno not in (errno.EACCES, errno.EAGAIN):
                        raise
                    if time.monotonic() >= until:
                        raise LaunchError("another lazygit action is still running; try again shortly")
                    time.sleep(0.05)
            yield
        finally:
            # Closing releases the OS lock even when a command fails. Never
            # unlink it: waiters must all keep coordinating on the same inode.
            os.close(fd)

    def identity(self, path):
        resolved = normalize_dir(path)
        if not resolved:
            return None
        if resolved in self.identity_cache:
            return self.identity_cache[resolved]
        identity = ("dir", resolved)
        for flag, kind in (("--show-toplevel", "worktree"), ("--absolute-git-dir", "bare")):
            result = self.command(["git", "-C", resolved, "rev-parse", flag],
                                  "repository identity", check=False)
            if result.returncode == 0:
                value = normalize_dir(result.stdout.strip())
                identity = (kind, value) if value else None
                break
        self.identity_cache[resolved] = identity
        return identity

    def pane_identity(self, pane):
        for key in ("foreground_cwd", "cwd"):
            identity = self.identity(pane.get(key))
            if identity:
                return identity
        return None

    def runs_lazygit(self, target):
        info = self.rpc("pane", "process-info", "--pane", target).get("process_info")
        if not isinstance(info, dict) or not isinstance(info.get("foreground_processes"), list):
            raise LaunchError("Herdr returned invalid process information")
        for process in info["foreground_processes"]:
            if not isinstance(process, dict):
                raise LaunchError("Herdr returned invalid process information")
            if any(process.get(key) is not None and not isinstance(process[key], str)
                   for key in ("name", "argv0")):
                raise LaunchError("Herdr returned invalid process names")
            names = [os.path.basename(process.get(key) or "") for key in ("name", "argv0")]
            if "lazygit" in names:
                return True
            # The entrypoint remains alive while generating config and while
            # displaying a startup error. Reuse that pane instead of creating
            # duplicates merely because lazygit itself isn't running yet.
            argv = process.get("argv") or []
            if not isinstance(argv, list) or any(not isinstance(arg, str) for arg in argv):
                raise LaunchError("Herdr returned invalid process arguments")
            if "bash" in names and len(argv) == 2 and argv[1] == str(SCRIPT_DIR / "run-lazygit.sh"):
                return True
        return False

    def decide(self):
        panes = self.rpc("pane", "list").get("panes")
        if not isinstance(panes, list) or any(not isinstance(p, dict) for p in panes):
            raise LaunchError("Herdr returned an invalid pane list")
        source = next((p for p in panes if p.get("pane_id") == self.origin["pane_id"]), None)
        if not source or any(source.get(key) != self.origin[key] for key in ("workspace_id", "tab_id")):
            raise LaunchError("the source pane moved or closed; invoke lazygit from your current pane")
        candidates = [p for p in panes
                      if p.get("workspace_id") == self.origin["workspace_id"]
                      and (self.placement == "tab" or p.get("tab_id") == self.origin["tab_id"])
                      and p.get("label") == "Git"]
        target_identity = self.identity(self.target_dir)
        candidates = [p for p in candidates if target_identity and self.pane_identity(p) == target_identity]
        matches = []
        for attempt in range(4 if candidates else 1):
            matches = [p for p in candidates if self.runs_lazygit(pane_id(p.get("pane_id")))]
            if matches:
                break
            if attempt < 3 and candidates:
                time.sleep(0.3)
        # p.focused can describe a different client's current view. Only the
        # pane that invoked this action can be toggled closed.
        for match in matches:
            if match["pane_id"] == self.origin["pane_id"]:
                return "CLOSE", match
        in_tab = [p for p in matches if p.get("tab_id") == self.origin["tab_id"]]
        if in_tab:
            return "FOCUS", in_tab[0]
        if matches:
            pane_id(matches[0].get("tab_id"))
            return "SWITCHTAB", matches[0]
        return "OPEN", None

    def act(self, decision, match):
        if decision == "CLOSE":
            self.rpc("plugin", "pane", "close", match["pane_id"])
        elif decision in ("FOCUS", "SWITCHTAB"):
            # Herdr plugin pane focus selects both the tab and the pane.
            self.rpc("plugin", "pane", "focus", match["pane_id"])
        else:
            args = ["plugin", "pane", "open", "--plugin", "herdr-lazygit",
                    "--entrypoint", "lazygit", "--placement", self.placement,
                    "--cwd", self.target_dir,
                    "--env", "HERDR_LAZYGIT_INITIAL_MODE=" + self.mode, "--focus"]
            if self.placement == "split":
                args += ["--target-pane", self.origin["pane_id"], "--direction", "right"]
            else:
                args += ["--workspace", self.origin["workspace_id"]]
            response = self.rpc(*args)
            try:
                target = pane_id(response["plugin_pane"]["pane"]["pane_id"])
            except (KeyError, TypeError):
                raise LaunchError("invalid open response; check existing panes before retrying") from None
            if self.placement == "split":
                self.command([sys.executable, str(SCRIPT_DIR / "layout-helper.py"),
                              "set-width", target, str(self.cols)], "initial pane width")

    def report_error(self, error):
        elapsed = time.monotonic() - self.started
        print("herdr-lazygit: {} failed after {:.2f}s (workspace={}): {}".format(
            self.stage, elapsed, self.origin.get("workspace_id", "unknown"), error), file=sys.stderr)
        if os.environ.get("HERDR_LAZYGIT_TEST_DECISION") == "1":
            return
        if self.stage == "launcher lock":
            message = "Another Git action is still running. Try again shortly."
        elif self.stage == "runtime/config precheck":
            message = "Check the lazygit runtime and plugin settings."
        elif self.stage == "initial pane width":
            message = "The Git pane opened, but its width could not be set."
        elif "source pane moved or closed" in str(error):
            message = "The source pane moved or closed. Try from your current pane."
        elif "timed out" in str(error) or "time limit" in str(error):
            message = "Herdr did not respond in time. Check for an existing Git pane before retrying."
        else:
            message = "The Git action could not finish."
        # Notification delivery may itself fail when Herdr is unavailable.
        # It must never hide the original error or keep the launcher alive.
        try:
            run_command([self.herdr, "notification", "show", "lazygit action failed",
                         "--body", message + " Details: herdr plugin log list",
                         "--sound", "none"], 0.5)
        except (OSError, subprocess.TimeoutExpired):
            pass


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("split", "tab"):
        print("usage: launcher.py split|tab", file=sys.stderr)
        return 2
    launcher = Launcher(sys.argv[1])
    def expired(signum, frame):
        raise LaunchError("launcher time limit reached; check existing panes before retrying")
    previous_alarm = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, TOTAL_TIMEOUT)
    try:
        launcher.configure()
        with launcher.lock():
            decision, match = launcher.decide()
            if os.environ.get("HERDR_LAZYGIT_TEST_DECISION") == "1":
                suffix = ""
                if match:
                    suffix = " " + match["tab_id" if decision == "SWITCHTAB" else "pane_id"]
                print(decision + suffix)
                print("DIR " + launcher.target_dir)
            else:
                launcher.act(decision, match)
                print(decision + (" " + match["pane_id"] if match else ""))
        return 0
    except (LaunchError, OSError) as error:
        signal.setitimer(signal.ITIMER_REAL, 0)
        launcher.report_error(error)
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_alarm)


if __name__ == "__main__":
    # Unwind run_command and lock on normal cancellation. SIGKILL still
    # releases the OS lock because it is never inherited by a child.
    def interrupted(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
