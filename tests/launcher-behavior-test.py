#!/usr/bin/env python3
"""Exercise real launcher subprocesses against a stateful, isolated Herdr stub."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import socketserver
import subprocess
import sys
import tempfile
import time
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
DRIVER = """
import launcher
launcher.COMMAND_TIMEOUT = 1.0
launcher.LOCK_TIMEOUT = 0.3
launcher.TOTAL_TIMEOUT = 4.0
raise SystemExit(launcher.main())
"""
FAKE_HERDR = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['FAKE_ROOT'])
args = sys.argv[1:]
state = json.loads((root/'panes.json').read_text())
entry = {'args': args, 'lock_fds': []}
inodes = [p.stat().st_ino for p in (root/'state'/'launcher-locks').glob('*.lock')]
for fd in range(3, 128):
    try:
        if os.fstat(fd).st_ino in inodes: entry['lock_fds'].append(fd)
    except OSError: pass
with (root/'calls').open('a') as log: log.write(json.dumps(entry)+'\n')
fault = os.environ.get('FAKE_FAULT', '')
if args[:2] == ['pane', 'list']:
    if fault in ('hang', 'inherited-output'):
        child = os.fork()
        if child == 0:
            (root/'descendant.pid').write_text(str(os.getpid()))
            time.sleep(30)
            os._exit(0)
        if fault == 'hang': time.sleep(30)
    if fault == 'bad-json': print('not json'); sys.exit(0)
    if fault == 'error-json': print(json.dumps({'error':{'code':'unavailable'}})); sys.exit(0)
    print(json.dumps({'result': {'panes': state}}))
elif args[:2] == ['pane', 'current']:
    print(json.dumps({'result': {'pane': state[0]}}))
elif args[:2] == ['pane', 'process-info']:
    cmdline = str(pathlib.Path(os.environ['HERDR_PLUGIN_ROOT'])/'scripts'/'run-lazygit.sh')
    name = 'bash' if fault == 'bootstrap' else 'lazygit'
    print(json.dumps({'result': {'process_info': {'foreground_processes':[
        {'name':name, 'argv0':name, 'cmdline':cmdline, 'argv':[name,cmdline]}]}}}))
elif args[:3] == ['plugin', 'pane', 'open']:
    if '--target-pane' in args:
        assert '--workspace' not in args, 'Herdr rejects workspace for split placement'
        workspace = next(p['workspace_id'] for p in state if p['pane_id']==args[args.index('--target-pane')+1])
    else:
        workspace = args[args.index('--workspace')+1]
    pane = {'pane_id':'new-git', 'workspace_id':workspace,
            'tab_id':'new-tab' if args[args.index('--placement')+1]=='tab' else 'tab-1',
            'label':'Git', 'cwd':args[args.index('--cwd')+1], 'focused':True}
    state.append(pane)
    (root/'panes.json').write_text(json.dumps(state))
    if fault == 'open-timeout': time.sleep(30)
    print(json.dumps({'result': {'plugin_pane': {'pane':pane}}}))
elif args[:3] in (['plugin','pane','focus'], ['plugin','pane','close']):
    print(json.dumps({'result': {'success':True}}))
elif args[:2] == ['notification','show']:
    if fault == 'notification-timeout': time.sleep(30)
    print(json.dumps({'result': {'success':True}}))
elif args[:2] == ['pane','layout']:
    if fault == 'layout-timeout':
        (root/'layout-child.pid').write_text(str(os.getpid()))
        time.sleep(30)
    print(json.dumps({'result': {'layout': {'tab_id':'tab-1', 'area': {'width':160},
        'panes':[{'pane_id':'source', 'rect':{'x':0,'width':80}},
                 {'pane_id':'new-git', 'rect':{'x':80,'width':80}}]}}}))
else:
    print('unexpected command', args, file=sys.stderr); sys.exit(2)
'''


class LauncherBehavior(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='herdr-launcher-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo with space ' 中文"
        self.repo.mkdir()
        (self.root / 'config').mkdir()
        self.fake = self.root / 'fake-herdr'
        self.fake.write_text(FAKE_HERDR)
        self.fake.chmod(0o755)
        self.source = dict(pane_id='source', workspace_id='ws-1', tab_id='tab-1',
                           label='Shell', cwd=str(self.repo), focused=True)
        self.write_panes([self.source])
        self.env = {key: value for key, value in os.environ.items() if not key.startswith('HERDR_')}
        self.env.update(HERDR_PLUGIN_ROOT=str(ROOT), HERDR_PLUGIN_CONFIG_DIR=str(self.root/'config'),
                        HERDR_PLUGIN_STATE_DIR=str(self.root/'state'),
                        HERDR_SOCKET_PATH=str(self.root/'herdr.sock'),
                        HERDR_LAZYGIT_BIN='/usr/bin/true', HERDR_BIN_PATH=str(self.fake),
                        PYTHONPATH=str(ROOT/'scripts'), FAKE_ROOT=str(self.root))
        self.set_context()
        self.addCleanup(self.kill_descendant)

    def kill_descendant(self):
        path = self.root/'descendant.pid'
        if path.exists():
            try: os.kill(int(path.read_text()), signal.SIGKILL)
            except ProcessLookupError: pass

    def set_context(self, **changes):
        context = dict(workspace_id='ws-1', tab_id='tab-1', focused_pane_id='source',
                       focused_pane_cwd=str(self.repo))
        context.update(changes)
        self.env['HERDR_PLUGIN_CONTEXT_JSON'] = json.dumps(context)

    def write_panes(self, panes):
        (self.root/'panes.json').write_text(json.dumps(panes))

    def git_pane(self, **changes):
        pane = dict(self.source, pane_id='git-pane', label='Git', focused=False)
        pane.update(changes)
        return pane

    def invoke(self, placement='tab'):
        return subprocess.run([sys.executable, '-c', DRIVER, placement], env=self.env,
                              capture_output=True, text=True, timeout=7)

    def calls(self):
        path = self.root/'calls'
        return [json.loads(line)['args'] for line in path.read_text().splitlines()] if path.exists() else []

    def test_new_tab_mode_and_explicit_workspace(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if c[:3] == ['plugin','pane','open'])
        self.assertIn('HERDR_LAZYGIT_INITIAL_MODE=expanded', call)
        self.assertEqual(call[call.index('--cwd')+1], str(self.repo))
        self.assertEqual(call[call.index('--workspace')+1], 'ws-1')
        self.assertFalse(any(c[:2] == ['pane','current'] for c in self.calls()))

    def test_tab_preference_and_invalid_value(self):
        conf = self.root/'config'/'panel.conf'
        conf.write_text('DEFAULT_MODE_TAB=sidebar\n')
        self.assertEqual(self.invoke().returncode, 0)
        self.assertIn('HERDR_LAZYGIT_INITIAL_MODE=sidebar', self.calls()[-1])
        self.write_panes([self.source])
        conf.write_text('DEFAULT_MODE_TAB=wrong\n')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('invalid initial tab layout', result.stderr)
        self.assertIn('HERDR_LAZYGIT_INITIAL_MODE=expanded', self.calls()[-1])

    def test_split_mode_and_width_are_selected_together(self):
        requests = []
        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                request = json.loads(self.rfile.readline())
                requests.append(request)
                if request['method'] == 'layout.export':
                    result = {'layout': {'root': {'type':'split', 'direction':'right',
                        'first': {'type':'pane', 'pane_id':'source'},
                        'second': {'type':'pane', 'pane_id':'new-git'}}}}
                else:
                    result = {'success':True}
                self.wfile.write((json.dumps({'result':result})+'\n').encode())
        with socketserver.UnixStreamServer(self.env['HERDR_SOCKET_PATH'], Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                for preference, mode, cols in [('', 'sidebar', 42),
                        ('DEFAULT_MODE_SPLIT=expanded\nEXPAND_COLS=120\n', 'expanded', 120),
                        ('DEFAULT_MODE_SPLIT=expanded\nEXPAND_COLS=500\n', 'expanded', 140),
                        ('DEFAULT_MODE_SPLIT=oops\n', 'sidebar', 42)]:
                    with self.subTest(preference=preference):
                        self.write_panes([self.source])
                        (self.root/'config'/'panel.conf').write_text(preference)
                        result = self.invoke('split')
                        self.assertEqual(result.returncode, 0, result.stderr)
                        call = [c for c in self.calls() if c[:3] == ['plugin','pane','open']][-1]
                        self.assertIn('HERDR_LAZYGIT_INITIAL_MODE='+mode, call)
                        self.assertEqual(call[call.index('--target-pane')+1], 'source')
                        self.assertAlmostEqual(requests[-1]['params']['ratio'], 1-cols/160)
            finally:
                server.shutdown()
                thread.join()

    def test_focus_bits_do_not_close_another_clients_pane(self):
        self.write_panes([dict(self.source, focused=False), self.git_pane(focused=True)])
        result = self.invoke('split')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[-1], ['plugin','pane','focus','git-pane'])

    def test_invoking_git_pane_toggles_closed_even_if_focus_changed(self):
        self.write_panes([self.source, self.git_pane()])
        self.set_context(focused_pane_id='git-pane')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[-1], ['plugin','pane','close','git-pane'])

    def test_cross_tab_reuse_focuses_the_matching_pane(self):
        self.write_panes([self.source, self.git_pane(tab_id='tab-2')])
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[-1], ['plugin','pane','focus','git-pane'])
        self.assertFalse(any('--env' in c for c in self.calls()))

    def test_bootstrap_is_reused_while_lazygit_is_starting(self):
        self.env['FAKE_FAULT'] = 'bootstrap'
        self.write_panes([self.source, self.git_pane()])
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[-1], ['plugin','pane','focus','git-pane'])

    def test_disappeared_source_fails_and_notifies(self):
        self.write_panes([])
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertIn('source pane moved or closed', result.stderr)
        self.assertEqual(self.calls()[-1][:2], ['notification','show'])
        self.assertFalse(any(c[:2] == ['plugin','pane'] for c in self.calls()))

    def test_bad_query_responses_never_become_open(self):
        for fault in ('bad-json', 'error-json'):
            with self.subTest(fault=fault):
                self.env['FAKE_FAULT'] = fault
                result = self.invoke()
                self.assertEqual(result.returncode, 1)
                self.assertFalse(any(c[:3] == ['plugin','pane','open'] for c in self.calls()))

    def test_descendant_retaining_output_does_not_hold_launcher(self):
        self.env['FAKE_FAULT'] = 'inherited-output'
        started = time.monotonic()
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic()-started, 3)
        for line in (self.root/'calls').read_text().splitlines():
            self.assertEqual(json.loads(line)['lock_fds'], [])

    def test_hung_query_times_out_and_releases_lock(self):
        self.env['FAKE_FAULT'] = 'hang'
        result = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertIn('timed out', result.stderr)
        self.env.pop('FAKE_FAULT')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_mutation_timeout_does_not_retry_and_next_invoke_reuses(self):
        self.env['FAKE_FAULT'] = 'open-timeout'
        self.assertEqual(self.invoke().returncode, 1)
        self.env.pop('FAKE_FAULT')
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(c[:3] == ['plugin','pane','open'] for c in self.calls()), 1)
        self.assertEqual(self.calls()[-1], ['plugin','pane','focus','new-git'])

    def test_timed_out_layout_helper_also_terminates_its_cli_child(self):
        self.env['FAKE_FAULT'] = 'layout-timeout'
        result = self.invoke('split')
        self.assertEqual(result.returncode, 1)
        self.assertIn('initial pane width', result.stderr)
        pid = int((self.root/'layout-child.pid').read_text())
        status = subprocess.run(['ps','-p',str(pid),'-o','stat='],
                                capture_output=True,text=True).stdout.strip()
        self.assertTrue(not status or status.startswith('Z'), status)
        self.env.pop('FAKE_FAULT')
        self.assertEqual(self.invoke('split').returncode, 0)
        self.assertEqual(sum(c[:3] == ['plugin','pane','open'] for c in self.calls()), 1)

    def test_concurrent_split_and_tab_share_lock(self):
        # Both actions can reuse a matching split. Concurrency must not turn
        # another client's focused bit into CLOSE, nor leak locks to commands.
        self.write_panes([self.source, self.git_pane(focused=True)])
        jobs = [subprocess.Popen([sys.executable,'-c',DRIVER,kind], env=self.env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                for kind in ('split','tab')]
        for process in jobs:
            out, err = process.communicate(timeout=7)
            self.assertEqual(process.returncode, 0, err)
        self.assertEqual(sum(c[:3] == ['plugin','pane','focus'] for c in self.calls()), 2)
        self.assertEqual(len(list((self.root/'state'/'launcher-locks').glob('*.lock'))), 1)

    def test_concurrent_new_tabs_create_only_one_pane(self):
        self.env['FAKE_FAULT'] = 'bootstrap'
        jobs = [subprocess.Popen([sys.executable,'-c',DRIVER,'tab'], env=self.env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                for _ in range(2)]
        successes = 0
        for process in jobs:
            out, err = process.communicate(timeout=7)
            if process.returncode == 0:
                successes += 1
            else:
                # A busy response is valid under heavy CI load; it must not
                # create anything, and a subsequent retry must reuse the pane.
                self.assertIn(b'another lazygit action', err)
        self.assertGreaterEqual(successes,1)
        self.assertEqual(self.invoke().returncode,0)
        self.assertEqual(sum(c[:3] == ['plugin','pane','open'] for c in self.calls()),1)
        panes = json.loads((self.root/'panes.json').read_text())
        self.assertEqual(sum(p.get('label')=='Git' for p in panes),1)

    def test_busy_scope_fails_but_other_workspace_or_server_can_proceed(self):
        lock_dir = self.root/'state'/'launcher-locks'
        lock_dir.mkdir(parents=True)
        scope = json.dumps([os.getuid(), os.path.realpath(self.env['HERDR_SOCKET_PATH']), 'ws-1'])
        key = hashlib.sha256(scope.encode()).hexdigest()[:24]
        with (lock_dir/(key+'.lock')).open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = self.invoke()
            self.assertEqual(result.returncode, 1)
            self.assertIn('another lazygit action', result.stderr)
            self.env['HERDR_SOCKET_PATH'] = str(self.root/'other-server.sock')
            self.assertEqual(self.invoke().returncode, 0)
            self.env['HERDR_SOCKET_PATH'] = str(self.root/'herdr.sock')
            self.set_context(workspace_id='ws-2')
            self.write_panes([dict(self.source, workspace_id='ws-2')])
            self.assertEqual(self.invoke().returncode, 0)


if __name__ == '__main__':
    unittest.main()
