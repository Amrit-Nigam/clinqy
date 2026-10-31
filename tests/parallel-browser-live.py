#!/usr/bin/env python3
"""Opt-in real-model regression: three owned browser jobs, scoped cancellation, then group fanout.
Requires the updated installed app and its connected extension. Uses localhost only; never signs in.
"""
import argparse
import json
from pathlib import Path
import subprocess
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--browser', default='Google Chrome')
    parser.add_argument('--timeout', type=float, default=150)
    parser.add_argument('--group-only', action='store_true')
    parser.add_argument('--exercise-shortcut-recovery', action='store_true')
    parser.add_argument('--real-websites', action='store_true')
    parser.add_argument('--active-form', action='store_true')
    parser.add_argument('--allow-foreground', action='store_true')
    args = parser.parse_args()
    support = Path.home() / 'Library/Application Support/Clinqy/cli'
    token = (Path.home() / '.config/clinqy/cli-token').read_text().strip()
    def link(host, **values):
        url = 'clinqy://' + host + '?' + urllib.parse.urlencode(dict(values, token=token), quote_via=urllib.parse.quote)
        subprocess.run(['/usr/bin/open', '-g', url], check=True, stdout=subprocess.DEVNULL)
    def status():
        key = str(uuid.uuid4())
        file = support / (key + '.json')
        link('status', id=key)
        until = time.monotonic() + 8
        while time.monotonic() < until:
            if file.exists():
                data = json.loads(file.read_text()); file.unlink(); return data
            time.sleep(.05)
        raise RuntimeError('App status unavailable')
    initial = status()
    reconnect_deadline = time.monotonic() + 20
    while args.browser not in initial.get('browserConnections', []) and time.monotonic() < reconnect_deadline:
        time.sleep(.3)
        initial = status()
    assert not initial.get('foregroundRunning') and not initial.get('backgroundJobs'), 'Use an idle app for the test'
    assert initial.get('backgroundLimit', 0) == 3, 'Set three slots before testing parallel jobs and queue admission'
    assert args.browser in initial.get('browserConnections', []), 'Requested browser extension is not connected'
    hits, done, lock = {}, set(), threading.Lock()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            name = self.path.strip('/')
            delay = 30000 if name == 'cancel' else 25000 if name == 'three' else 10000
            html = '''<!doctype html><title>Parallel local test</title><h1>Job NAME</h1>
            <button onclick="this.disabled=true;fetch('/hit/NAME',{method:'POST'});setTimeout(()=>{document.querySelector('p').textContent='NAME complete';fetch('/done/NAME',{method:'POST'})},DELAY)">Start NAME</button><p>Waiting</p>'''.replace('NAME', name).replace('DELAY', str(delay))
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(html.encode())
        def do_POST(self):
            operation, name = self.path.strip('/').split('/', 1)
            with lock:
                if operation == 'hit': hits[name] = hits.get(name, 0) + 1
                if operation == 'done': done.add(name)
            self.send_response(204); self.end_headers()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    seen_jobs, receipts = set(), []
    def request(text, background=True):
        receipt = str(uuid.uuid4()); receipts.append(receipt)
        link('run', task=('in the background: ' if background else 'foreground: ') + text, test='1', id=receipt)
        return receipt
    def foreground_result(receipt):
        deadline = time.monotonic() + args.timeout
        browser_samples = 0
        file = support / (receipt + '.run.json')
        while time.monotonic() < deadline:
            current = status()
            assert not current.get('backgroundJobs'), 'Current-tab request unexpectedly created a background job'
            if current.get('browserCursorActive'):
                browser_samples += 1
                if browser_samples > 2: assert current.get('primaryCursorSuppressed'), 'Native companion overlaps the browser cursor'
            if file.exists():
                result = json.loads(file.read_text()); file.unlink()
                assert result['ok'], result['answer']
                assert browser_samples > 2, 'Browser cursor ownership was not observed during the foreground task'
                return result
            time.sleep(.2)
        raise AssertionError('Current-tab task did not finish before timeout')
    def goal(name):
        recovery = (f'First use open_app for {args.browser}, then try key cmd+t once. If refused, recover with open_url without asking me. ' if args.exercise_shortcut_recovery else '')
        return (recovery + f'On {args.browser}, open http://127.0.0.1:{server.server_port}/{name} in your own task tab. '
                f'Click Start {name} exactly once, wait for the exact text "{name} complete", verify it, and finish with that text in your answer. '
                'Use only your own tab and leave it open. This is a local test; do not ask questions or use any other page.')
    def collect(ids, cancel_first=False, grouped=False):
        results, peak, coordinated, stopped, queued = {}, 0, False, False, False
        indicator_since, cursor_expected = None, None
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline and len(results) < len(ids):
            current = status()
            if not args.allow_foreground: assert not current['foregroundRunning'], 'Browser jobs occupied the native foreground controller'
            jobs = current.get('backgroundJobs', [])
            seen_jobs.update(j['id'] for j in jobs)
            if jobs:
                expected = bool(current.get('inputPanelVisible')) or bool(current.get('browserCursorActive')) or not current['foregroundRunning']
                if cursor_expected != expected: cursor_expected, indicator_since = expected, time.monotonic()
                if time.monotonic() - indicator_since > .4: assert current.get('primaryCursorSuppressed') == expected, 'Cursor ownership did not match foreground/background activity'
            assert all(j['phase'] != 'waiting' for j in jobs), 'A local browser task unnecessarily asked for user input'
            peak = max(peak, sum(j['started'] and not j['coordinating'] for j in jobs))
            queued |= any(not j['started'] for j in jobs)
            coordinated |= any(j['coordinating'] for j in jobs)
            with lock: started = hits.get('cancel', 0) > 0
            if cancel_first and peak >= 3 and started and not stopped:
                link('cancel', receipt=ids[0]); stopped = True
            for receipt in ids:
                file = support / (receipt + '.run.json')
                if receipt not in results and file.exists():
                    results[receipt] = json.loads(file.read_text()); file.unlink()
            time.sleep(.15)
        assert len(results) == len(ids), 'Tasks did not return their individual receipts before timeout'
        assert peak >= 3, f'Only {peak} jobs were observed running together'
        assert peak <= initial['backgroundLimit'], 'Browser concurrency exceeded its configured limit'
        if cancel_first: assert queued, 'Fourth browser job did not queue at capacity'
        if grouped: assert coordinated, 'Explicit parallel request did not create a coordinator'
        return [results[key] for key in ids]
    def check_indicator_cleanup():
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if status().get('backgroundIndicators') == 0:
                print('PASS completed cursor indicators disappear automatically', flush=True)
                return
            time.sleep(.2)
        raise AssertionError('Completed task cursors remained visible past their expiry')
    try:
        if args.active_form:
            original, replacement, textarea = ['CLINQY-' + uuid.uuid4().hex[:10] for _ in range(3)]
            url = 'https://www.selenium.dev/selenium/web/web-form.html'
            setup = request(f'Open {url} in a new test tab in {args.browser}, using open_app followed by open_url. Do not use keyboard shortcuts or address-bar typing to navigate. Fill only the Text input field with {original}. Verify its exact value, then finish. Keep the browser in front. Do not submit the form.', background=False)
            foreground_result(setup)
            page_before = subprocess.check_output(['bin/clinqy', 'page'], text=True)
            assert original in page_before and url in page_before, 'Initial test form value was not actually present'
            task = request(f'Show me the already-open Selenium Web form tab in {args.browser} and work in it. Do not open, duplicate, reload or navigate any tab. First read the existing value of Text input and include that original value in your final answer. Then replace Text input with {replacement} and set Textarea to {textarea}. Verify the exact resulting values. Do not submit. Keep the browser in front. Finish concisely with the original value, both resulting values and current page URL.', background=False)
            result = foreground_result(task)
            page_after = subprocess.check_output(['bin/clinqy', 'page'], text=True)
            assert original in result['answer'], 'The second task did not read the original existing-tab value'
            assert all(value in page_after for value in (url, replacement, textarea)), 'Live form fields do not contain the requested values'
            assert not any('Go to ' in step for step in result.get('steps', [])), 'The existing-tab task navigated instead of using its open form'
            print('PASS existing real website tab: original field read, text input replaced, textarea filled, exact live values verified, no navigation or submission', flush=True)
            return 0
        if args.real_websites:
            cases = [
                ('Wikipedia search', 'Open https://en.wikipedia.org. Use Wikipedia search to find Ada Lovelace, open her article, and read her birth date. Verify the date on the article. Report the exact birth date and the article URL.',
                 ['10', '1815', 'december', 'en.wikipedia.org']),
                ('Python documentation search', 'Open https://docs.python.org/3/. Use documentation search to find pathlib, open its reference, find Path.cwd(), and read what it returns. Verify that section. Report the method, what it returns, and the reference URL.',
                 ['path.cwd', 'current', 'directory', 'docs.python.org']),
                ('MDN reference search', 'Open https://developer.mozilla.org/en-US/. Use site search to find Array.prototype.map, open its JavaScript reference, and read whether it returns a new array. Verify the reference text. Report the method, its return behavior, and the reference URL.',
                 ['array.prototype.map', 'new array', 'developer.mozilla.org']),
            ]
            ids = [request(f'On {args.browser}, {goal} Work only in your own inactive task tab. Use the real site search and read its actual result; do not answer from memory. Do not log in or change accounts. Leave your result tab open. Finish only after verifying the answer on the page.') for _, goal, _ in cases]
            outcomes = collect(ids)
            failures = []
            for (name, _, expected), result in zip(cases, outcomes):
                passed = result['ok'] and all(word in result['answer'].lower() for word in expected)
                if not passed: failures.append(name)
                print(('PASS ' if passed else 'FAIL ') + name + ': ' + result['answer'], flush=True)
            if not failures: print('PASS three real website workflows in parallel, verified answers, and free foreground controller', flush=True)
            check_indicator_cleanup()
            assert not failures, 'Real website failures: ' + ', '.join(failures)
            return 0
        if not args.group_only:
            ids = [request(goal(name)) for name in ('cancel', 'beta', 'gamma', 'delta')]
            outcomes = collect(ids, cancel_first=True)
            assert not outcomes[0]['ok'] and outcomes[0]['answer'] == 'Stopped', 'Cancellation reached the wrong request'
            for name, result in zip(('beta', 'gamma', 'delta'), outcomes[1:]):
                assert result['ok'] and name + ' complete' in result['answer'], name + ' did not independently finish'
                assert name in done and hits[name] == 1, name + ' fixture result was wrong or duplicated'
            print('PASS three simultaneous browser jobs, fourth-job queue admission, scoped cancellation, independent results, and free foreground controller', flush=True)
        group = request('Use 3 tabs and work simultaneously on these independent goals:\n' + '\n'.join(goal(name) for name in ('one', 'two', 'three')))
        result = collect([group], grouped=True)[0]
        assert result['ok'], result['answer']
        for name in ('one', 'two', 'three'):
            assert hits.get(name) == 1 and name in done and name + ' complete' in result['answer'], 'Group child outcome missing: ' + name
        print('PASS one request fans out to three independent browser jobs and aggregates their verified results', flush=True)
        check_indicator_cleanup()
    finally:
        for receipt in receipts:
            try: link('cancel', receipt=receipt)
            except Exception: pass
        for job in seen_jobs:
            try: link('task', id=job, op='dismiss')
            except Exception: pass
        server.shutdown(); server.server_close()
    return 0

if __name__ == '__main__': raise SystemExit(main())
