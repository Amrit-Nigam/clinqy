#!/usr/bin/env python3
"""Independent local browser outcome scoring. No third-party dependencies; no model calls in dry-run."""
import argparse
import json
import math
import os
from pathlib import Path
import secrets
import statistics
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CASES = [
    ('name', 'Fill Name with Amrit and do not submit.', {'name': 'Amrit'}),
    ('multiline', 'Fill Message with two lines, first Hello and then World. Do not submit.', {'message': 'Hello\nWorld'}),
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clinqy', default=str(Path(__file__).resolve().parents[2] / 'bin/clinqy'))
    parser.add_argument('--case', action='append', choices=[c[0] for c in CASES])
    parser.add_argument('--label', default='default', help='Configuration label (do not include secrets)')
    parser.add_argument('--timeout', type=float, default=180)
    parser.add_argument('--out', type=Path, default=Path('benchmark-results.json'))
    parser.add_argument('--foreground', action='store_true', help='Takes over foreground input; default uses background owned tabs')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    selected = [case for case in CASES if not args.case or case[0] in args.case]
    if args.dry_run:
        print(json.dumps([{'name': name, 'task': task, 'expected': expected} for name, task, expected in selected], indent=2)); return 0
    if args.timeout <= 0 or not math.isfinite(args.timeout): parser.error('timeout must be positive and finite')
    states, lock = {}, threading.Lock()
    fixture = Path(__file__).with_name('site.html').read_bytes()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            if not self.path.startswith('/case?'): self.send_error(404); return
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.end_headers(); self.wfile.write(fixture)
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
    try:
        for name, task, expected in selected:
            token = secrets.token_hex(16)
            with lock: states[token] = None
            url = f'http://127.0.0.1:{server.server_port}/case?token={token}'
            request = ('' if args.foreground else 'in the background: ') + f'Open {url}. ' + task.format(attachment=attachment)
            begun = time.monotonic(); timed_out = False
            try:
                result = subprocess.run([args.clinqy, 'run', '--test', request], capture_output=True, text=True, timeout=args.timeout)
                reported = result.returncode == 0
                output = result.stdout + result.stderr
            except subprocess.TimeoutExpired:
                timed_out = True; reported = False; output = 'Timed out; app task may still be running. Stop it before another run.'
            # Allow already-dispatched fixture reports to reach the independent recorder.
            time.sleep(.2)
            with lock: state = states[token]
            row = {'name': name, 'reported_success': reported, 'seconds': round(time.monotonic() - begun, 3),
                   'timed_out': timed_out, **score(expected, state, reported),
                   'fixture_state_received': state is not None, 'agent_output': output[-8000:],
                   'interventions': None, 'recovery_attempts': None, 'model_cost': None, 'foreground_interruptions': None}
            rows.append(row)
            print(('PASS' if row['verified_completion'] else 'FAIL') + ' ' + name, flush=True)
            payload = {'label': args.label, 'mode': 'foreground' if args.foreground else 'background',
                       'scoring': 'fixture outcome independent of agent verdict', 'summary': summary(rows), 'results': rows}
            args.out.write_text(json.dumps(payload, indent=2) + '\n')
            if timed_out: break  # Never launch another task into an unresolved previous run.
    finally:
        server.shutdown(); server.server_close(); attachment.unlink(missing_ok=True)
    print(json.dumps(summary(rows), indent=2))
    return 0 if len(rows) == len(selected) and all(r['verified_completion'] and r['reported_success'] for r in rows) else 1

if __name__ == '__main__': raise SystemExit(main())
