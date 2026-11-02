#!/usr/bin/env python3
"""Independent local browser outcome scoring. No third-party dependencies; no model calls in dry-run."""
import argparse
import json
import math
import os
from pathlib import Path
import secrets
import signal
import uuid
import statistics
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CASES = [
    ('name', 'Fill Name with Amrit and do not submit.', {'name': 'Amrit'}),
    ('multiline', 'Fill Message with two lines, first Hello and then World. Do not submit.', {'message': 'Hello\nWorld'}),
    ('keyboard', 'Fill Name with Old, focus Name, use Cmd+A then type Fresh to replace it using the keyboard. Leave Message empty.', {'name': 'Fresh', 'message': ''}),
    ('checkbox', 'Tick Design panel.', {'checked': True}),
    ('dropdown', 'Set City to Pune.', {'city': 'Pune'}),
    ('hover', 'Hover over Show hint to reveal its hint, without clicking it.', {'hint': True}),
    ('context', 'Right-click Open local menu and verify Local menu ready.', {'context': 1}),
    ('double', 'Double-click Open details twice exactly once.', {'details': 1}),
    ('drag', 'Drag Drag card to Drop zone using a pointer drag.', {'dragged': True}),
    ('delayed', 'Click Generate report once and wait until the current result shows report is true.', {'report': True}),
    ('rerender', 'Click Save draft once exactly once.', {'saved': 1}),
    ('iframe', 'Fill Embedded name inside the Embedded form with Priya.', {'embedded': 'Priya'}),
    ('shadow', 'Fill Shadow name with Rahul.', {'shadow': 'Rahul'}),
    ('submit', 'Click Submit local sample once, then verify submitted is 1. This is an authorized local test.', {'submitted': 1}),
    ('vision', 'Read the code drawn in Visual card and enter it in Visual code.', {'visual': 'MANGO-482'}),
    ('navigation', 'Click Open result section and verify its heading.', {'navigated': True}),
    ('upload', 'Attach the local text file {attachment} to Attachment without submitting.', {'attachment': 'Clinqy benchmark attachment'}),
]


def score(expected, state, reported_success):
    """The fixture's observed state, never the agent's verdict, determines completion."""
    valid = isinstance(state, dict)
    wrong = state.get('wrong', 0) if valid else 0
    duplicates = sum(max(0, state.get(key, 0) - 1) for key in ('context', 'details', 'saved', 'submitted')) if valid else 0
    matched = valid and all(type(state.get(k)) is type(v) and state[k] == v for k, v in expected.items())
    verified = bool(matched and wrong == 0 and duplicates == 0)
    return {'verified_completion': verified, 'false_success': bool(reported_success and not verified),
            'wrong_target_actions': wrong, 'duplicate_effects': duplicates}


def summary(rows):
    durations = sorted(row['seconds'] for row in rows)
    count = len(rows)
    return {'tasks': count, 'verified_completions': sum(r['verified_completion'] for r in rows),
            'verified_completion_rate': sum(r['verified_completion'] for r in rows) / count if count else None,
            'false_successes': sum(r['false_success'] for r in rows),
            'wrong_target_actions': sum(r['wrong_target_actions'] for r in rows),
            'duplicate_effects': sum(r['duplicate_effects'] for r in rows),
            'median_seconds': statistics.median(durations) if count else None,
            'p95_seconds': durations[max(0, math.ceil(count * .95) - 1)] if count else None}


PROVIDERS = ['agy', 'claude', 'codex', 'anthropic', 'openai', 'gemini', 'openrouter', 'ollama', 'compatible']


def task_text(browser, url, task, attachment, foreground=False):
    return ('' if foreground else 'in the background: ') + f'In {browser}, open {url}. ' + task.format(attachment=attachment)


def save_results(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(payload, indent=2) + '\n')
    temporary.replace(path)


class OwnedRun:
    """Own a receipt, not the foreground controller; every cleanup is scoped to this UUID."""
    def __init__(self, cli, directory=None, runner=subprocess.run):
        self.cli, self.runner = cli, runner
        self.receipt = str(uuid.uuid4())
        self.path = (directory or Path.home() / 'Library/Application Support/Clinqy/cli') / (self.receipt + '.run.json')
        self.result = None
        self.dispatched = False

    def read(self):
        try:
            result = json.loads(self.path.read_text())
            if not isinstance(result, dict) or type(result.get('ok')) is not bool:
                return None
            self.result = result
            return result
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    def dispatch(self, request, provider=None):
        command = [self.cli, 'run', '--test', '--receipt', self.receipt, '--no-wait']
        if provider: command += ['--provider', provider]
        # Mark first: launch failure may happen after the app received the URL.
        self.dispatched = True
        result = self.runner(command + [request], capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise RuntimeError((result.stdout + result.stderr)[-4000:])

    def wait(self, timeout, stop):
        deadline = time.monotonic() + timeout
        while not stop.is_set() and time.monotonic() < deadline:
            if self.read() is not None: return self.result
            stop.wait(min(.1, max(0, deadline - time.monotonic())))
        return None

    def cancel(self, timeout=15):
        if self.read() is not None or not self.dispatched: return True
        deadline = time.monotonic() + timeout
        while True:
            try:
                self.runner([self.cli, 'cancel', '--receipt', self.receipt], capture_output=True, text=True, timeout=5)
            except (OSError, subprocess.TimeoutExpired): pass
            # A cancellation URL being accepted is not proof of task termination.
            if self.wait(min(2, max(0, deadline - time.monotonic())), threading.Event()) is not None: return True
            if time.monotonic() >= deadline: return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clinqy', default=str(Path(__file__).resolve().parents[2] / 'bin/clinqy'))
    parser.add_argument('--case', action='append', choices=[c[0] for c in CASES])
    parser.add_argument('--browser', default='Google Chrome', choices=['Google Chrome', 'Arc', 'Brave Browser', 'Microsoft Edge'], help='Explicit task browser; never inherit the foreground app')
    parser.add_argument('--provider', choices=PROVIDERS, help='Per-run provider; leaves global settings unchanged')
    parser.add_argument('--label', default='default', help='Configuration label (do not include secrets)')
    parser.add_argument('--timeout', type=float, default=180)
    parser.add_argument('--out', type=Path, default=Path('benchmark-results.json'))
    parser.add_argument('--foreground', action='store_true', help='Takes over foreground input; default uses background owned tabs')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    selected = [case for case in CASES if not args.case or case[0] in args.case]
    if args.dry_run:
        print(json.dumps([{'name': name, 'task': task_text(args.browser, '<fixture-url>', task, '<attachment>', args.foreground), 'provider': args.provider, 'expected': expected} for name, task, expected in selected], indent=2)); return 0
    if args.timeout <= 0 or not math.isfinite(args.timeout): parser.error('timeout must be positive and finite')
    states, lock = {}, threading.Lock()
    visual_codes = {}
    fixture = Path(__file__).with_name('site.html').read_bytes()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            if not self.path.startswith('/case?'): self.send_error(404); return
            from urllib.parse import urlparse, parse_qs
            token = parse_qs(urlparse(self.path).query).get('token', [''])[0]
            with lock: code = visual_codes.get(token)
            if code is None: self.send_error(404); return
            page = fixture.replace(b'MANGO-482', code.encode('ascii'))
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.end_headers(); self.wfile.write(page)
        def do_POST(self):
            token = self.path.removeprefix('/record/')
            with lock: allowed = token in states
            if not self.path.startswith('/record/') or not allowed: self.send_error(404); return
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size < 100_000: raise ValueError('size')
                state = json.loads(self.rfile.read(size))
                if not isinstance(state, dict): raise ValueError('state')
                for key in ('context', 'details', 'saved', 'submitted', 'wrong'):
                    if type(state.get(key)) is not int or state[key] < 0: raise ValueError('counter')
            except (ValueError, TypeError): self.send_error(400); return
            with lock: states[token] = state
            self.send_response(204); self.end_headers()

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    attachment = Path(os.environ.get('TMPDIR', '/tmp')) / ('clinqy-benchmark-' + secrets.token_hex(8) + '.txt')
    attachment.write_text('Clinqy benchmark attachment')
    rows = []
    stop = threading.Event()
    old_signals = {sig: signal.signal(sig, lambda *_: stop.set()) for sig in (signal.SIGINT, signal.SIGTERM)}
    def persist():
        save_results(args.out, {'label': args.label, 'browser': args.browser, 'provider': args.provider,
            'mode': 'foreground' if args.foreground else 'background',
            'scoring': 'fixture outcome independent of agent verdict', 'summary': summary(rows), 'results': rows})
    try:
        for name, task, expected in selected:
            if stop.is_set(): break
            token = secrets.token_hex(16)
            with lock:
                states[token] = None
                visual_codes[token] = 'TEST-' + secrets.token_hex(3).upper()
            if name == 'vision': expected = {'visual': visual_codes[token]}
            url = f'http://127.0.0.1:{server.server_port}/case?token={token}'
            request = task_text(args.browser, url, task, attachment, args.foreground)
            owned = OwnedRun(args.clinqy)
            begun = time.monotonic(); timed_out = False; reported = False; output = ''; cancelled = None
            row = {'name': name, 'receipt': owned.receipt, 'status': 'running', 'seconds': 0,
                   **score(expected, None, False)}
            rows.append(row)
            persist()  # Preserve ownership even if launch is interrupted.
            try:
                if stop.is_set(): break
                owned.dispatch(request, args.provider)
                result = owned.wait(args.timeout, stop)
                timed_out = result is None and not stop.is_set()
                if result is not None:
                    reported = result['ok']
                    output = '\n'.join(result.get('steps', [])) + '\n' + result.get('answer', '')
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                output = str(error)
            finally:
                cancelled = owned.cancel()
                row['cancellation_confirmed'] = cancelled
                if not cancelled: output += '\nCancellation unconfirmed; inspect owned receipt ' + owned.receipt
            # Allow already-dispatched fixture reports to reach the independent recorder.
            time.sleep(.2)
            with lock: state = states[token]
            row.update({'reported_success': reported, 'seconds': round(time.monotonic() - begun, 3),
                   'status': 'interrupted' if stop.is_set() else 'timeout' if timed_out else 'finished',
                   'timed_out': timed_out, **score(expected, state, reported),
                   'fixture_state_received': state is not None, 'agent_output': output[-8000:],
                   'interventions': None, 'recovery_attempts': None, 'model_cost': None, 'foreground_interruptions': None})
            print(('INTERRUPTED' if row['status'] == 'interrupted' else 'PASS' if row['verified_completion'] else 'FAIL') + ' ' + name, flush=True)
            persist()
            if timed_out or stop.is_set() or not cancelled: break
    finally:
        persist()
        for sig, handler in old_signals.items(): signal.signal(sig, handler)
        server.shutdown(); server.server_close(); attachment.unlink(missing_ok=True)
    print(json.dumps(summary(rows), indent=2))
    return 0 if len(rows) == len(selected) and all(r['verified_completion'] and r.get('reported_success') and r.get('cancellation_confirmed') for r in rows) else 1

if __name__ == '__main__': raise SystemExit(main())
