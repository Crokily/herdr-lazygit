#!/usr/bin/env python3
"""Real runtime/Herdr regression in a disposable server with its own sockets.

Usage: python3 tests/herdr-smoke-test.py /absolute/path/to/herdr
Requires the plugin-private runtime and tests/requirements.txt. Never attaches to or
changes the user's existing Herdr session. AI generation uses a local stub.
"""
import json
import fcntl
import os
from pathlib import Path
import shutil
import pty
import select
import signal
import subprocess
import sys
import struct
import tempfile
import termios
import threading
import time

import pyte
from wcwidth import wcwidth

ROOT = Path(__file__).resolve().parents[1]


class ClientScreen(pyte.Screen):
    @property
    def display(self):
        # A partial repaint can overwrite the first half of a wide character
        # while its empty continuation cell remains. pyte 0.8.2 indexes that
        # empty string in Screen.display. Render orphan cells as blanks while
        # still skipping the continuation of an intact wide character.
        lines = []
        for y in range(self.lines):
            cells = []
            x = 0
            while x < self.columns:
                value = self.buffer[y][x].data or ' '
                cells.append(value)
                x += max(1, wcwidth(value[0]))
            lines.append(''.join(cells))
        return lines

    def report_device_status(self, mode=0, **kwargs):
        # Herdr queries private terminal capabilities. The fixture emulates
        # rendered cells, not a physical terminal's capability replies. pyte
        # 0.8.2's base DSR handler does not accept the private keyword.
        if not kwargs.get('private'):
            super().report_device_status(mode)


def main():
    herdr = os.path.realpath(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix='hlg-smoke-') as directory:
        base = Path(directory)
        repo = base / "repo space ' 中文"
        repo.mkdir()
        config = base/'config.toml'
        # 0.7.0 prioritizes its default new-worktree binding over a custom
        # command on the same key. Explicitly free the key in this fixture.
        config.write_text('onboarding = false\n[terminal]\ndefault_shell = "/bin/sh"\n'
                          '[keys]\nnew_worktree = []\n'
                          '[[keys.command]]\nkey = "prefix+shift+g"\ntype = "plugin_action"\n'
                          'command = "herdr-lazygit.open-tab"\n')
        # Every server/config/runtime path is private to this fixture. Clearing
        # inherited Herdr variables prevents accidentally targeting a live user
        # session, including when the test itself is launched inside Herdr.
        env = {k: v for k, v in os.environ.items() if not k.startswith('HERDR_')}
        env.update(HERDR_CONFIG_PATH=str(config), HERDR_SOCKET_PATH=str(base/'api.sock'),
                   XDG_CONFIG_HOME=str(base/'config'), XDG_STATE_HOME=str(base/'state'),
                   XDG_DATA_HOME=str(base/'data'), XDG_CACHE_HOME=str(base/'cache'),
                   GIT_AUTHOR_NAME='Runtime Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                   GIT_COMMITTER_NAME='Runtime Test', GIT_COMMITTER_EMAIL='test@example.invalid')
        def run(argv, **kwargs):
            return subprocess.run(argv, env=env, capture_output=True, text=True,
                                  timeout=15, check=True, **kwargs).stdout
        run(['git','init','-q',str(repo)])
        (repo/'test.txt').write_text('before\n')
        run(['git','-C',str(repo),'add','.'])
        run(['git','-C',str(repo),'commit','-qm','initial'])
        diff_text = 'HLG_VISIBLE_DIFF_LINE'
        (repo/'test.txt').write_text(diff_text+'\n')
        run(['git','-C',str(repo),'add','.'])
        log = (base/'server.log').open('w')
        server = subprocess.Popen([herdr,'server'], env=env, cwd=repo,
                                  stdout=log, stderr=log, start_new_session=True)
        client = None
        master = None
        client_output = bytearray()
        screen = ClientScreen(180,45)
        stream = pyte.ByteStream(screen)
        screen_lock = threading.Lock()
        def visible_client():
            with screen_lock:
                return '\n'.join(screen.display)
        def pane_screen(pane):
            return run([herdr,'pane','read',pane,'--source','visible','--lines','80'])
        def cli(*args):
            output = run([herdr,*args])
            return json.loads(output)['result'] if output.strip() else {}
        def wait_for(predicate, label):
            deadline = time.monotonic()+8
            while time.monotonic() < deadline:
                value = predicate()
                if value:
                    return value
                if server.poll() is not None:
                    raise AssertionError('test server exited')
                time.sleep(.1)
            raise AssertionError('timed out waiting for '+label)
        def panes():
            return cli('pane','list')['panes']
        def labeled(label):
            return [p for p in panes() if p.get('label') == label]
        def has_process(pane, name):
            info = cli('pane','process-info','--pane',pane)['process_info']
            if any(p.get('name') == name for p in info.get('foreground_processes') or []):
                return True
            # Some Herdr versions report only the noninteractive Bash
            # entrypoint as the foreground job. For this local test fixture,
            # verify its actual descendants independently; production launcher
            # identification uses only Herdr's official process-info response.
            descendants = {info.get('shell_pid')}
            processes = []
            for line in run(['ps','-axo','pid=,ppid=,comm=']).splitlines():
                fields = line.split(None,2)
                if len(fields)==3:
                    processes.append((int(fields[0]),int(fields[1]),os.path.basename(fields[2])))
            while True:
                added = {pid for pid,parent,_ in processes if parent in descendants}-descendants
                if not added: break
                descendants.update(added)
            return any(pid in descendants and command==name for pid,_,command in processes)
        def pane_exists(pane):
            return any(p['pane_id']==pane for p in panes())
        try:
            wait_for(lambda:(base/'api.sock').exists(), 'private test socket')
            # Old Herdr versions update geometry while drawing an attached
            # client. Exercise that real path with a private PTY, not a user's
            # terminal. Drain output so rendering cannot block on a full PTY.
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH',45,180,0,0))
            def child_terminal():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)
            client = subprocess.Popen([herdr], env=dict(env, TERM='xterm-256color'), cwd=repo,
                                      stdin=slave, stdout=slave, stderr=slave,
                                      preexec_fn=child_terminal)
            os.close(slave)
            def drain():
                while client.poll() is None:
                    try:
                        if select.select([master],[],[],.1)[0]:
                            data = os.read(master,65536)
                            with screen_lock:
                                stream.feed(data)
                            client_output.extend(data)
                            del client_output[:-16000]
                    except OSError: break
            reader = threading.Thread(target=drain, daemon=True)
            reader.start()
            wait_for(lambda:cli('workspace','list')['workspaces'], 'attached test client')
            version = run([herdr,'--version']).strip()
            cli('plugin','link',str(ROOT))
            plugin_config = Path(run([herdr,'plugin','config-dir','herdr-lazygit']).strip())
            plugin_config.mkdir(parents=True, exist_ok=True)
            (plugin_config/'panel.conf').write_text('INHERIT_USER_CONFIG=0\n')
            (plugin_config/'lazygit-user.yml').write_text('disableStartupPopups: true\n')
            (plugin_config/'ai-backend.conf').write_text(
                "AI_BACKEND=custom\nAI_CUSTOM_CMD=\"printf 'test: exercise commit pane\\\\n'\"\n")
            source = cli('workspace','create','--cwd',str(repo),'--focus')['root_pane']
            action_env = dict(env, HERDR_BIN_PATH=herdr, HERDR_PLUGIN_ROOT=str(ROOT),
                              HERDR_PLUGIN_CONFIG_DIR=str(plugin_config))
            def invoke(kind, origin=source):
                action_env['HERDR_PLUGIN_CONTEXT_JSON'] = json.dumps({
                    'workspace_id':origin['workspace_id'], 'tab_id':origin['tab_id'],
                    'focused_pane_id':origin['pane_id'], 'focused_pane_cwd':str(repo)})
                script = 'open-lazygit-tab.sh' if kind=='tab' else 'open-lazygit.sh'
                result = subprocess.run(['bash',str(ROOT/'scripts'/script)], env=action_env,
                                        capture_output=True, text=True, timeout=15)
                if result.returncode:
                    raise AssertionError(result.stderr)
                return result.stdout.strip()
            def new_layer(previous):
                return wait_for(lambda:next(iter(set(plugin_config.glob('layout-*.yml'))-previous),None),
                                'pane layout layer')
            def mode_is(layer, mode):
                return layer.exists() and ('# layout: '+mode+'\n') in layer.read_text()
            def width(pane):
                layout = cli('pane','layout','--pane',pane)['layout']
                return next(p['rect']['width'] for p in layout['panes'] if p['pane_id']==pane)

            # Run the manifest action too, testing Herdr's action cwd and
            # injected plugin environment, not just a direct script invocation.
            before = set(plugin_config.glob('layout-*.yml'))
            cli('plugin','action','invoke','open','--plugin','herdr-lazygit')
            git_pane = wait_for(lambda:next(iter(labeled('Git')),None), 'split pane')['pane_id']
            wait_for(lambda:has_process(git_pane,'lazygit'), 'real lazygit process')
            layer = new_layer(before)
            assert mode_is(layer,'sidebar'), layer.read_text()
            wait_for(lambda:abs(width(git_pane)-42)<=2, 'sidebar width')
            wait_for(lambda:'test.txt' in pane_screen(git_pane), 'initial lazygit rendering')
            cli('pane','send-text',git_pane,'\x1b[O\x1b[I')
            cli('pane','send-text',git_pane,'U')
            wait_for(lambda:mode_is(layer,'expanded'), 'Expand custom command')
            target_width = min(110, cli('pane','layout','--pane',git_pane)['layout']['area']['width']-20)
            wait_for(lambda:abs(width(git_pane)-target_width)<=2, 'expanded width')
            wait_for(lambda:'+'+diff_text in pane_screen(git_pane), 'rendered diff after Expand')
            expanded_width = width(git_pane)

            # Keep lazygit focused and toggle repeatedly. An extra focus-in
            # alone is ignored once lazygit already considers itself focused.
            for next_mode in ('sidebar','expanded','sidebar','expanded'):
                cli('pane','send-text',git_pane,'U')
                wait_for(lambda:mode_is(layer,next_mode), next_mode+' layout')
                if next_mode == 'expanded':
                    wait_for(lambda:'+'+diff_text in pane_screen(git_pane), 'rendered expanded diff')
                else:
                    wait_for(lambda:diff_text not in pane_screen(git_pane), 'rendered sidebar without diff')

            # Settings and Commit exercise the actual fzf, preview commands,
            # lazygit contexts, shell quoting, and supporting-pane cleanup.
            for key, label in [(';','GitSettings'), ('2C','GitCommit')]:
                cli('pane','send-text',git_pane,key)
                helper = wait_for(lambda:next(iter(labeled(label)),None), label)['pane_id']
                wait_for(lambda:has_process(helper,'fzf'), label+' fzf process')
                cli('pane','send-text',helper,'\x1b')
                wait_for(lambda:not pane_exists(helper), label+' close')
                assert mode_is(layer,'expanded'), 'support pane reset the mode'
                wait_for(lambda:abs(width(git_pane)-expanded_width)<=2, 'restored width')
            assert run(['git','-C',str(repo),'rev-list','--count','HEAD']).strip()=='1'
            assert invoke('tab').startswith('FOCUS')
            assert len(labeled('Git'))==1 and mode_is(layer,'expanded')

            # A different tab reuses the same pane and focuses it, rather than
            # only selecting whichever pane the destination tab last focused.
            other = cli('tab','create','--workspace',source['workspace_id'],
                        '--cwd',str(repo),'--focus')['root_pane']
            assert invoke('tab',other).startswith('SWITCHTAB')
            assert cli('pane','current')['pane']['pane_id']==git_pane
            # A custom command can leave lazygit's main view on its command
            # log. Preserve that user state; the live file list still proves
            # this client selected the Git pane instead of the empty shell tab.
            wait_for(lambda:'test.txt' in visible_client(), 'visible client cross-tab switch')
            target = next(p for p in panes() if p['pane_id']==git_pane)
            assert invoke('split',target).startswith('CLOSE')
            wait_for(lambda:not pane_exists(git_pane), 'toggle close')

            before = set(plugin_config.glob('layout-*.yml'))
            assert invoke('tab',other).startswith('OPEN')
            git_pane = labeled('Git')[0]['pane_id']
            wait_for(lambda:has_process(git_pane,'lazygit'), 'tab lazygit process')
            layer = new_layer(before)
            assert mode_is(layer,'expanded'), layer.read_text()
            layout = cli('pane','layout','--pane',git_pane)['layout']
            assert len(layout['panes'])==1
            wait_for(lambda:'+'+diff_text in visible_client(), 'visible client new Git tab')
            tab_width = width(git_pane)
            cli('pane','send-text',git_pane,'U')
            wait_for(lambda:mode_is(layer,'sidebar'), 'full-tab toggle')
            assert width(git_pane)==tab_width, 'single-pane tab was narrowed'
            cli('plugin','pane','close',git_pane)

            # Trigger the actual configured prefix+shift+g through the client
            # PTY. Neither focused=true nor a tab-bar label proves that the
            # client switched; require the diff content in the rendered grid.
            cli('tab','focus',other['tab_id'])
            cli('pane','run',other['pane_id'], "printf '\\nHLG_SOURCE_VIEW\\n'")
            wait_for(lambda:'HLG_SOURCE_VIEW' in visible_client(), 'source client view')
            os.write(master,b'\x02G')
            git_pane = wait_for(lambda:next(iter(labeled('Git')),None), 'keybinding Git tab')['pane_id']
            wait_for(lambda:'+'+diff_text in visible_client(), 'keybinding visible Git diff')
            for _ in range(2):
                cli('tab','focus',other['tab_id'])
                wait_for(lambda:'HLG_SOURCE_VIEW' in visible_client(), 'source view before repeat')
                os.write(master,b'\x02G')
                wait_for(lambda:'+'+diff_text in visible_client(), 'repeated keybinding visible Git diff')
                assert len(labeled('Git'))==1 and labeled('Git')[0]['pane_id']==git_pane
            cli('plugin','pane','close',git_pane)

            (plugin_config/'panel.conf').write_text(
                'INHERIT_USER_CONFIG=0\nDEFAULT_MODE_SPLIT=expanded\nEXPAND_COLS=100\n')
            before = set(plugin_config.glob('layout-*.yml'))
            assert invoke('split').startswith('OPEN')
            git_pane = labeled('Git')[0]['pane_id']
            wait_for(lambda:has_process(git_pane,'lazygit'), 'expanded split lazygit')
            assert mode_is(new_layer(before),'expanded')
            layout = cli('pane','layout','--pane',git_pane)['layout']
            assert 1 <= width(git_pane) <= min(102, layout['area']['width']-18)
            # The action log must report a failed precheck as failed, with the
            # offending override visible, while leaving the existing pane up.
            (plugin_config/'panel.conf').write_text("RUNTIME_LAZYGIT_BIN='/missing/test-runtime'\n")
            cli('plugin','action','invoke','open','--plugin','herdr-lazygit')
            wait_for(lambda:any(log.get('status')=='failed' and '/missing/test-runtime' in log.get('stderr','')
                                for log in cli('plugin','log','list','--plugin','herdr-lazygit')['logs']),
                     'visible action failure')
            assert pane_exists(git_pane)
            print(version+': real runtime, C/U/;, rendered layouts, client keybinding focus, reuse and close passed')
        except BaseException:
            print('Herdr smoke failure; server output:\n'+(base/'server.log').read_text()[-2500:], file=sys.stderr)
            print('Visible client screen:\n'+visible_client(), file=sys.stderr)
            # These are only this fixture's terminals. Output helps diagnose a
            # config rejection or shell error that leaves a readable error pane.
            if server.poll() is None and (base/'api.sock').exists():
                print(run([herdr,'plugin','log','list','--plugin','herdr-lazygit'])[-4000:], file=sys.stderr)
                for pane in panes():
                    print(run([herdr,'pane','layout','--pane',pane['pane_id']])[-1800:], file=sys.stderr)
                    print(run([herdr,'pane','process-info','--pane',pane['pane_id']])[-2500:], file=sys.stderr)
                    print(run([herdr,'pane','read',pane['pane_id'],'--lines','25'])[-3000:], file=sys.stderr)
            artifacts = os.environ.get('HERDR_LAZYGIT_TEST_ARTIFACT_DIR')
            if artifacts:
                destination = Path(artifacts)
                destination.mkdir(parents=True, exist_ok=True)
                for path in base.rglob('*.log'):
                    if path.is_file() and not path.is_symlink():
                        target = destination/path.relative_to(base)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(path,target)
                (destination/'client.ansi').write_bytes(client_output)
                (destination/'client-screen.txt').write_text(visible_client())
            raise
        finally:
            if client is not None:
                client.terminate()
                try: client.wait(timeout=3)
                except subprocess.TimeoutExpired: client.kill(); client.wait()
            if master is not None:
                reader.join(timeout=1)
                os.close(master)
            # Stop only the process/socket created above. There is no fallback
            # to a user's default server if startup failed.
            if server.poll() is None:
                if (base/'api.sock').exists():
                    try: cli('server','stop')
                    except Exception: pass
                try: server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(server.pid,signal.SIGKILL)
                    server.wait()
            log.close()


if __name__ == '__main__':
    main()
