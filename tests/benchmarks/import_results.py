#!/usr/bin/env python3
"""Normalize externally collected local-fixture outcomes without trusting a tool's success claim."""
import argparse
import json
import math
from pathlib import Path

from run import ALL_CASES, SCHEMA_VERSION, score, save_results, summary


def normalize(raw):
    if not isinstance(raw, dict): raise ValueError('result document must be an object')
    if not isinstance(raw.get('tool'), str) or not raw['tool'].strip(): raise ValueError('tool name required')
    for key in ('browser', 'mode'):
        if not isinstance(raw.get(key), str) or not raw[key].strip(): raise ValueError(f'{key} required')
    identity = raw.get('fixture_sha256', '')
    if not isinstance(identity, str) or len(identity) != 64 or any(c not in '0123456789abcdef' for c in identity): raise ValueError('fixture SHA-256 required')
    cases = {name: (task, expected) for name, task, expected in ALL_CASES}
    rows = []
    if not isinstance(raw.get('runs'), list): raise ValueError('runs must be a list')
    for entry in raw['runs']:
        if not isinstance(entry, dict): raise ValueError('each run must be an object')
        name = entry.get('name')
        if name not in cases: raise ValueError(f'unknown case {name}')
        task, expected = cases[name]
        if name == 'vision':
            code = entry.get('visual_code')
            if not isinstance(code, str) or not code.startswith('TEST-'): raise ValueError('record the independently generated visual code')
            expected = {'visual': code}
        seconds = entry.get('seconds')
        if type(seconds) not in (int, float) or not math.isfinite(seconds) or seconds < 0: raise ValueError('finite duration required')
        verdict = entry.get('reported_success')
        if type(verdict) is not bool: raise ValueError('boolean reported_success required')
        state = entry.get('fixture_state')
        if not isinstance(state, dict): raise ValueError('independent fixture_state required')
        for key in ('wrong', 'submitted'):
            if type(state.get(key)) is not int or state[key] < 0: raise ValueError('fixture counters required')
        rows.append({'name': name, 'iteration': entry.get('iteration', 1), 'task_template': task,
                     'seconds': seconds, 'status': 'finished', 'reported_success': verdict,
                     'expected': expected, 'fixture_state': state, **score(expected, state, verdict)})
    if not rows: raise ValueError('runs must contain actual measurements')
    return {'schema_version': SCHEMA_VERSION, 'label': raw['tool'], 'provider': raw.get('provider'),
            'browser': raw['browser'], 'mode': raw['mode'],
            'fixture_sha256': identity, 'environment': raw.get('environment'), 'cancellation_experiment': None,
            'measurement_origin': 'externally-collected-fixture-evidence',
            'scoring': 'recomputed from supplied fixture states; evidence origin not independently audited',
            'results': rows, 'summary': summary(rows)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path); parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    try: save_results(args.out, normalize(json.loads(args.input.read_text())))
    except (OSError, ValueError, TypeError, KeyError) as error: parser.error(str(error))
    return 0


if __name__ == '__main__': raise SystemExit(main())
