#!/usr/bin/env python3
"""Independent local browser outcome scoring. No third-party dependencies; no model calls in dry-run."""
import argparse
import hashlib
import json
import math
import os
import platform
import plistlib
from pathlib import Path
import secrets
import signal
import uuid
import statistics
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CASES = [
    ('name', 'Fill Name with Amrit and do not submit.', {'name': 'Amrit'}),
    ('multiline', 'Fill Message with two lines, first Hello and then World. Do not submit.', {'message': 'Hello\nWorld'}),
    ('keyboard', 'Fill Name with Old, focus Name, use Cmd+A then type Fresh to replace it using the keyboard. Leave Message empty.', {'name': 'Fresh', 'message': ''}),
    ('checkbox', 'Tick Design panel.', {'checked': True}),
    ('dropdown', 'Set City to Pune.', {'city': 'Pune'}),
    ('range', 'Set Range level to 65 using the numeric set_state action once, then independently verify the value is 65. Do not submit or change other controls.', {'range_value': 65, 'range_changes': 1, 'submitted': 0}),
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

WORKFLOW_CASES = [
    ('richtext', 'Replace the Draft editor with exactly Ready for review. Leave Other editor unchanged.', {'draft': 'Ready for review', 'other': 'Leave this editor alone'}),
    ('autocomplete', 'Choose Priya Shah from the Reviewer suggestions. Verify the selected reviewer.', {'reviewer': 'Priya Shah'}),
    ('nested-scroll', 'Scroll inside Checklist panel and tick Final checklist item. Do not click Wrong target.', {'final_checked': True}),
    ('popup', 'Open Review window once, click Confirm local review in that new window once, then return to the workspace. Do not submit the workspace.', {'popup_opened': 1, 'popup_confirmed': 1, 'submitted': 0}),
    ('session-recovery', 'Open session report. If this local fixture session is expired, click Sign in local session, then open the report again and verify Session report ready. Do not submit the workflow.', {'session_signed_in': True, 'session_report': True, 'session_attempts': 2, 'submitted': 0}),
    ('workflow', 'Fill Project name with Release draft. Replace Draft editor with Ready for review. Choose Priya Shah as Reviewer, tick Final checklist item inside Checklist panel, attach {attachment}, click Prepare preview once and wait for Preview ready. Then click Submit local workflow once and verify Workflow accepted. These are authorized local fixture actions.', {'project': 'Release draft', 'draft': 'Ready for review', 'other': 'Leave this editor alone', 'reviewer': 'Priya Shah', 'final_checked': True, 'attachment': 'Clinqy benchmark attachment', 'preview_count': 1, 'preview_ready': True, 'submitted': 1, 'accepted': True}),
    ('download', 'Click Download local report once. Wait for the download to finish and verify the resulting file {download} contains Clinqy benchmark report. Do not submit anything.', {'download_requested': 1, 'download_verified': True}),
]
ALL_CASES = CASES + WORKFLOW_CASES
COUNTERS = ('context', 'details', 'saved', 'submitted', 'range_changes', 'popup_opened', 'popup_confirmed', 'preview_count', 'download_requested')
SCHEMA_VERSION = 2


def score(expected, state, reported_success):
    """The fixture's observed state, never the agent's verdict, determines completion."""
    valid = isinstance(state, dict) and all(key not in state or (type(state[key]) is int and state[key] >= 0)
                                           for key in COUNTERS + ('wrong',))
    wrong = state.get('wrong', 0) if valid else 0
    duplicates = sum(max(0, state.get(key, 0) - 1) for key in COUNTERS) if valid else 0
    matched = valid and all(type(state.get(k)) is type(v) and state[k] == v for k, v in expected.items())
    verified = bool(matched and wrong == 0 and duplicates == 0)
    return {'verified_completion': verified, 'false_success': bool(reported_success and not verified),
            'wrong_target_actions': wrong, 'duplicate_effects': duplicates}


def summary(rows):
    durations = sorted(row['seconds'] for row in rows)
    count = len(rows)
    return {'tasks': count, 'verified_completions': sum(r['verified_completion'] for r in rows),
            'finished_tasks': sum(r.get('status', 'finished') == 'finished' for r in rows),
            'cancelled_tasks': sum(r.get('status') == 'cancelled' for r in rows),
            'interrupted_tasks': sum(r.get('status') == 'interrupted' for r in rows),
            'verified_completion_rate': sum(r['verified_completion'] for r in rows) / count if count else None,
            'false_successes': sum(r['false_success'] for r in rows),
            'wrong_target_actions': sum(r['wrong_target_actions'] for r in rows),
            'duplicate_effects': sum(r['duplicate_effects'] for r in rows),
            'median_seconds': statistics.median(durations) if count else None,
            'p95_seconds': durations[max(0, math.ceil(count * .95) - 1)] if count else None}


PROVIDERS = ['agy', 'claude', 'codex', 'anthropic', 'openai', 'gemini', 'openrouter', 'ollama', 'compatible']


def task_text(browser, url, task, attachment, foreground=False, download='<download>'):
    return ('' if foreground else 'in the background: ') + f'In {browser}, open {url}. ' + task.format(attachment=attachment, download=download)


def finite_metrics(result):
    metrics = result.get('phaseMilliseconds', {}) if isinstance(result, dict) else {}
    if not isinstance(metrics, dict): return {}
    return {key: value for key, value in metrics.items() if isinstance(key, str)
            and type(value) in (int, float) and math.isfinite(value) and value >= 0}


def installed_metadata(app, diagnostic_file=None):
    """Read actual bundle data; never label source version as installed version."""
    result = {'os': platform.platform(), 'machine': platform.machine(), 'app_bundle': str(app),
              'installed_app_version': None, 'installed_extension_version': None,
              'connected_extension_status': None}
    try:
        with (app / 'Contents/Info.plist').open('rb') as stream: info = plistlib.load(stream)
        result['installed_app_version'] = info.get('CFBundleShortVersionString')
    except (OSError, ValueError, plistlib.InvalidFileException): pass
    try:
        manifest = json.loads((app / 'Contents/Resources/extension/manifest.json').read_text())
        result['installed_extension_version'] = manifest.get('version')
    except (OSError, ValueError): pass
    if diagnostic_file:
        # The app's status JSON is supplied explicitly; no hidden app launch or copied profile identifiers.
        raw = json.loads(diagnostic_file.read_text())
        statuses = raw.get('extensionStatuses', raw.get('browserExtensionStatuses', []))
        result['connected_extension_status'] = [{key: entry[key] for key in
            ('browser', 'version', 'build', 'expectedVersion', 'expectedBuild', 'compatible') if key in entry}
            for entry in statuses if isinstance(entry, dict)]
    return result


def file_matches(path, expected):
    try:
        return not path.is_symlink() and path.is_file() and path.stat().st_size == len(expected) and path.read_bytes() == expected
    except OSError: return False


class DesktopMonitor:
    """Optional passive sampler in its own process. It cannot move the pointer or activate an app."""
    def __init__(self, enabled):
        self.process = None; self.directory = None; self.output = None; self.stop_file = None; self.error = None
        if not enabled: return
        self.directory = tempfile.TemporaryDirectory(prefix='clinqy-observer-')
        root = Path(self.directory.name)
        self.output, self.stop_file = root / 'observation.json', root / 'stop'
        try:
            self.process = subprocess.Popen(['/usr/bin/swift', str(Path(__file__).with_name('desktop_monitor.swift')),
                str(self.output), str(self.stop_file)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and self.process.poll() is None:
                if self.output.with_suffix('.json.ready').exists(): return
                time.sleep(.05)
            self.error = 'passive sampler unavailable or did not initialize'
        except OSError as error: self.error = str(error)

    def finish(self):
        measured = None
        if self.process:
            self.stop_file.write_text('stop')
            try: self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try: self.process.wait(timeout=2)
                except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
            if self.error is None:
                try: measured = json.loads(self.output.read_text())
                except (OSError, ValueError): self.error = 'sampler returned no readable measurement'
        if self.directory: self.directory.cleanup()
        return measured


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
    parser.add_argument('--case', action='append', choices=[c[0] for c in ALL_CASES])
    parser.add_argument('--suite', choices=['controls', 'workflows', 'all'], default='controls')
    parser.add_argument('--browser', default='Google Chrome', choices=['Google Chrome', 'Arc', 'Brave Browser', 'Microsoft Edge'], help='Explicit task browser; never inherit the foreground app')
    parser.add_argument('--provider', choices=PROVIDERS, help='Per-run provider; leaves global settings unchanged')
    parser.add_argument('--label', default='default', help='Configuration label (do not include secrets)')
    parser.add_argument('--timeout', type=float, default=180)
    parser.add_argument('--out', type=Path, default=Path('benchmark-results.json'))
    parser.add_argument('--foreground', action='store_true', help='Takes over foreground input; default uses background owned tabs')
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--download-directory', type=Path, help='Chrome actual download directory; required for download case; never changes browser settings')
    parser.add_argument('--cancel-after', type=float, help='Explicit cancellation experiment: cancel this receipt after N seconds; no browser/process termination')
    parser.add_argument('--installed-app', type=Path, default=Path('/Applications/Clinqy.app'))
    parser.add_argument('--diagnostics', type=Path, help='Fresh app status JSON captured separately; connected build unknown when omitted')
    parser.add_argument('--monitor-desktop', action='store_true', help='Passively sample focus, pointer, clipboard and visible window-order change counts; cannot attribute changes while user is active')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    catalog = ALL_CASES if args.case or args.suite == 'all' else CASES if args.suite == 'controls' else WORKFLOW_CASES
    selected = [case for case in catalog if not args.case or case[0] in args.case]
    if not 1 <= args.repeat <= 100: parser.error('repeat must be between 1 and 100')
    if any(case[0] == 'download' for case in selected) and args.download_directory is None:
        parser.error('download case requires --download-directory pointing to Chrome actual download directory')
    if args.cancel_after is not None and (not math.isfinite(args.cancel_after) or args.cancel_after <= 0):
        parser.error('cancel-after must be positive and finite')
    if args.dry_run:
        print(json.dumps([{'name': name, 'task': task_text(args.browser, '<fixture-url>', task, '<attachment>', args.foreground), 'provider': args.provider, 'expected': expected} for name, task, expected in selected], indent=2)); return 0
    if args.timeout <= 0 or not math.isfinite(args.timeout): parser.error('timeout must be positive and finite')
    states, lock = {}, threading.Lock()
    visual_codes = {}
    fixtures = {name: Path(__file__).with_name(name).read_bytes() for name in ('site.html', 'workflow.html', 'popup.html')}
    fixture_hash = hashlib.sha256(b''.join(fixtures.values())).hexdigest()
    try: metadata = installed_metadata(args.installed_app, args.diagnostics)
    except (OSError, ValueError, TypeError, AttributeError) as error: parser.error('invalid diagnostics: ' + str(error))

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            from urllib.parse import urlparse, parse_qs
            parsed = urlparse(self.path)
            token = parse_qs(parsed.query).get('token', [''])[0]
            with lock: code = visual_codes.get(token)
            if code is None: self.send_error(404); return
            if parsed.path == '/download':
                self.send_response(200); self.send_header('Content-Type', 'text/plain')
                self.send_header('Content-Disposition', f'attachment; filename="clinqy-report-{token}.txt"')
                body = b'Clinqy benchmark report\n'; self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body); return
            file = {'/case': 'site.html', '/workflow': 'workflow.html', '/popup': 'popup.html'}.get(parsed.path)
            if file is None: self.send_error(404); return
            page = fixtures[file].replace(b'MANGO-482', code.encode('ascii'))
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
                for key in COUNTERS + ('wrong',):
                    if key in state and (type(state[key]) is not int or state[key] < 0): raise ValueError('counter')
                if type(state.get('wrong')) is not int or type(state.get('submitted')) is not int: raise ValueError('required counters')
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
        save_results(args.out, {'schema_version': SCHEMA_VERSION, 'fixture_sha256': fixture_hash,
            'environment': metadata, 'label': args.label, 'browser': args.browser, 'provider': args.provider,
            'mode': 'foreground' if args.foreground else 'background',
            'repeat': args.repeat, 'cancellation_experiment': args.cancel_after,
            'scoring': 'fixture outcome independent of agent verdict', 'summary': summary(rows), 'results': rows})
    try:
        for iteration, (name, task, expected) in ((iteration, case) for iteration in range(1, args.repeat + 1) for case in selected):
            if stop.is_set(): break
            token = secrets.token_hex(16)
            with lock:
                states[token] = None
                visual_codes[token] = 'TEST-' + secrets.token_hex(3).upper()
            if name == 'vision': expected = {'visual': visual_codes[token]}
            route = 'workflow' if name in {case[0] for case in WORKFLOW_CASES} else 'case'
            url = f'http://127.0.0.1:{server.server_port}/{route}?token={token}'
            download = args.download_directory / f'clinqy-report-{token}.txt' if args.download_directory else None
            request = task_text(args.browser, url, task, attachment, args.foreground, str(download or '<download>'))
            owned = OwnedRun(args.clinqy)
            timed_out = False; reported = False; output = ''; cancelled = None; result = None
            row = {'name': name, 'iteration': iteration, 'receipt': owned.receipt, 'status': 'running', 'seconds': 0,
                   'task_template': task, 'expected': expected,
                   **score(expected, None, False)}
            rows.append(row)
            persist()  # Preserve ownership even if launch is interrupted.
            monitor = DesktopMonitor(args.monitor_desktop)
            begun = time.monotonic()  # Do not charge Swift sampler startup to the automation.
            try:
                if stop.is_set(): raise InterruptedError('Interrupted before task dispatch')
                owned.dispatch(request, args.provider)
                result = owned.wait(min(args.timeout, args.cancel_after) if args.cancel_after is not None else args.timeout, stop)
                timed_out = result is None and not stop.is_set() and args.cancel_after is None
                if result is not None:
                    reported = result['ok']
                    output = '\n'.join(str(step) for step in (result.get('steps') or [])) + '\n' + str(result.get('answer', ''))
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                output = str(error)
            finally:
                try: cancelled = owned.cancel()
                except OSError as error:
                    cancelled = False; output += '\nCould not confirm cancellation: ' + str(error)
                finally: desktop = monitor.finish()
                row['cancellation_confirmed'] = cancelled
                if not cancelled: output += '\nCancellation unconfirmed; inspect owned receipt ' + owned.receipt
            # Allow already-dispatched fixture reports to reach the independent recorder.
            time.sleep(.2)
            with lock: state = dict(states[token]) if states[token] is not None else None
            if name == 'download' and state is not None:
                state['download_verified'] = file_matches(download, b'Clinqy benchmark report\n')
            cancellation_requested = args.cancel_after is not None and result is None
            metrics = finite_metrics(result or owned.result)
            row.update({'reported_success': reported, 'seconds': round(time.monotonic() - begun, 3),
                   'status': 'interrupted' if stop.is_set() else 'cancelled' if cancellation_requested else 'timeout' if timed_out else 'finished',
                   'timed_out': timed_out, **score(expected, state, reported),
                   'fixture_state_received': state is not None, 'fixture_state': state, 'agent_output': output[-8000:],
                   'phase_milliseconds': metrics or None, 'phase_metrics_source': 'app receipt' if metrics else None,
                   'desktop_observation': desktop, 'desktop_monitor_error': monitor.error,
                   'download_path': str(download) if name == 'download' else None,
                   'interventions': None, 'recovery_attempts': None, 'model_cost': None, 'foreground_interruptions': None})
            print(('INTERRUPTED' if row['status'] == 'interrupted' else 'PASS' if row['verified_completion'] else 'FAIL') + ' ' + name, flush=True)
            persist()
            if timed_out or stop.is_set() or not cancelled or cancellation_requested: break
    finally:
        persist()
        for sig, handler in old_signals.items(): signal.signal(sig, handler)
        server.shutdown(); server.server_close(); attachment.unlink(missing_ok=True)
    print(json.dumps(summary(rows), indent=2))
    return 0 if len(rows) == len(selected) * args.repeat and all(r['verified_completion'] and r.get('reported_success') and r.get('cancellation_confirmed') for r in rows) else 1

if __name__ == '__main__': raise SystemExit(main())
