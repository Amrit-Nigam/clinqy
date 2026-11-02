import unittest
from run import score, summary

class ScoringTests(unittest.TestCase):
    def test_false_success(self):
        self.assertTrue(score({'name': 'Amrit'}, {'name': 'wrong'}, True)['false_success'])
        self.assertFalse(score({'name': 'Amrit'}, None, True)['verified_completion'])
    def test_independent_completion(self):
        result = score({'name': 'Amrit'}, {'name': 'Amrit'}, False)
        self.assertTrue(result['verified_completion'])
        self.assertFalse(result['false_success'])
    def test_wrong_target_or_duplicate_fails(self):
        self.assertFalse(score({'saved': 1}, {'saved': 1, 'wrong': 1}, True)['verified_completion'])
        result = score({'name': 'Amrit'}, {'name': 'Amrit', 'submitted': 2}, True)
        self.assertFalse(result['verified_completion'])
        self.assertEqual(result['duplicate_effects'], 1)
    def test_boolean_not_integer(self):
        self.assertFalse(score({'saved': 1}, {'saved': True}, True)['verified_completion'])
    def test_summary(self):
        self.assertIsNone(summary([])['median_seconds'])
        rows = [dict(seconds=n, **score({'ok': True}, {'ok': n < 3}, True)) for n in (1, 2, 3)]
        self.assertEqual(summary(rows)['verified_completions'], 2)
        self.assertEqual(summary(rows)['p95_seconds'], 3)


class OwnershipTests(unittest.TestCase):
    def test_cancel_exact_receipt_and_preserve_unrelated(self):
        import tempfile, json, subprocess, threading
        from pathlib import Path
        from run import OwnedRun
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            unrelated = directory / 'unrelated.run.json'; unrelated.write_text('{"ok": true}')
            calls = []
            def runner(command, **kwargs):
                calls.append(command)
                if command[1] == 'cancel':
                    owned.path.write_text(json.dumps({'ok': False, 'answer': 'Stopped'}))
                return subprocess.CompletedProcess(command, 0, '', '')
            owned = OwnedRun('clinqy', directory, runner)
            owned.dispatch('In Google Chrome, do local work', 'codex')
            self.assertIsNone(owned.wait(.01, threading.Event()))
            self.assertTrue(owned.cancel(.1))
            self.assertEqual(calls[1], ['clinqy', 'cancel', '--receipt', owned.receipt])
            self.assertIn('--provider', calls[0]); self.assertIn('codex', calls[0])
            self.assertTrue(unrelated.exists())
            self.assertEqual(owned.result['answer'], 'Stopped')

    def test_dispatch_failure_still_cancels_owned_task(self):
        import tempfile, subprocess
        from pathlib import Path
        from run import OwnedRun
        calls = []
        def runner(command, **kwargs):
            calls.append(command)
            if command[1] == 'run': raise subprocess.TimeoutExpired(command, 15)
            owned.path.write_text('{"ok": false, "answer": "Stopped"}')
            return subprocess.CompletedProcess(command, 0, '', '')
        with tempfile.TemporaryDirectory() as root:
            owned = OwnedRun('clinqy', Path(root), runner)
            with self.assertRaises(subprocess.TimeoutExpired): owned.dispatch('request')
            self.assertTrue(owned.cancel(.1))
            self.assertEqual(calls[-1][1:3], ['cancel', '--receipt'])

    def test_completed_receipt_needs_no_cancel(self):
        import tempfile
        from pathlib import Path
        from run import OwnedRun, save_results, task_text
        with tempfile.TemporaryDirectory() as root:
            owned = OwnedRun('clinqy', Path(root), lambda *a, **k: self.fail('unexpected command'))
            owned.path.write_text('{"ok": true, "answer": "done"}')
            self.assertTrue(owned.cancel())
            target = Path(root) / 'partial.json'
            save_results(target, {'receipt': owned.receipt, 'status': 'interrupted'})
            self.assertIn('interrupted', target.read_text())
            self.assertIn('In Google Chrome, open ', task_text('Google Chrome', 'url', 'test', 'file'))

    def test_cli_flags_without_launching_app(self):
        import tempfile, subprocess, os, json
        from pathlib import Path
        cli = Path(__file__).resolve().parents[2] / 'bin/clinqy'
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            capture = root / 'open.json'
            for name, body in [('pgrep', '#!/bin/sh\nexit 0\n'), ('open', '#!/usr/bin/python3\nimport os,json,sys\nopen(os.environ["CAPTURE"],"w").write(json.dumps(sys.argv[1:]))\n')]:
                file = root / name; file.write_text(body); file.chmod(0o755)
            env = dict(os.environ, HOME=str(root), PATH=str(root) + ':' + os.environ['PATH'], CAPTURE=str(capture))
            receipt = '11111111-1111-1111-1111-111111111111'
            result = subprocess.run([str(cli), 'run', '--test', '--receipt', receipt, '--no-wait', '--provider', 'codex', 'fixture only'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            link = json.loads(capture.read_text())[-1]
            self.assertIn('provider=codex', link); self.assertIn('id=' + receipt, link)
            result = subprocess.run([str(cli), 'cancel', '--receipt', receipt], env=env, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertIn('cancel?receipt=' + receipt, json.loads(capture.read_text())[-1])
            capture.unlink()
            for flags in [['cancel'], ['run', '--provider', 'unsupported', 'test'], ['run', '--no-wait', 'test']]:
                self.assertNotEqual(subprocess.run([str(cli)] + flags, env=env, capture_output=True).returncode, 0)
                self.assertFalse(capture.exists())

if __name__ == '__main__': unittest.main()
