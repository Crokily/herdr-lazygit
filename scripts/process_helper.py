#!/usr/bin/env python3
"""Bounded child commands, without pipe-EOF or inherited-lock dependencies."""
import os
import signal
import subprocess
import tempfile


def run_command(argv, timeout=3.0, env=None):
    # A descendant can retain stdout after its parent exits. Temporary files
    # let us wait for the command itself, not for every writer to close a pipe.
    # close_fds also ensures a launcher's flock never reaches a child.
    owned_group = os.environ.get("HERDR_LAZYGIT_COMMAND_GROUP") != "1"
    child_env = dict(os.environ if env is None else env)
    # Nested helpers stay in the supervisor's group, so killing a timed-out
    # layout helper also terminates its Herdr CLI child. A standalone helper
    # creates its own group. This flag never crosses the Herdr server into a
    # newly opened user pane.
    child_env["HERDR_LAZYGIT_COMMAND_GROUP"] = "1"
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        process = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
            env=child_env, close_fds=True, start_new_session=owned_group,
        )
        try:
            process.wait(timeout=timeout)
        except BaseException:
            if not owned_group:
                process.kill()
            raise
        finally:
            if owned_group:
                # CLI/precheck commands have no background service lifecycle.
                # Reap descendants even if their leader exited successfully.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait()
        stdout.seek(0)
        stderr.seek(0)
        return subprocess.CompletedProcess(
            argv, process.returncode,
            stdout.read(2 * 1024 * 1024).decode('utf-8', errors='replace'),
            stderr.read(16 * 1024).decode('utf-8', errors='replace'),
        )
