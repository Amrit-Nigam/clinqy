#!/usr/bin/env python3
"""Compare like-for-like recorded results; never launches a browser, model, or competing tool."""
import argparse
import json
import math
from pathlib import Path

from run import SCHEMA_VERSION, summary


def load_report(path):
    report = json.loads(path.read_text())
    if not isinstance(report, dict): raise ValueError('result document must be an object')
    if report.get('schema_version') != SCHEMA_VERSION: raise ValueError(f'{path}: unsupported result schema')
    if not isinstance(report.get('fixture_sha256'), str) or len(report['fixture_sha256']) != 64:
        raise ValueError(f'{path}: missing fixture identity')
    for key in ('browser', 'mode'):
        if not isinstance(report.get(key), str) or not report[key].strip():
            raise ValueError(f'{path}: missing {key}')
    if any(character not in '0123456789abcdef' for character in report['fixture_sha256']):
        raise ValueError(f'{path}: invalid fixture identity')
    rows = report.get('results')
    if not isinstance(rows, list) or not rows: raise ValueError(f'{path}: no measurements')
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('name'), str): raise ValueError('invalid result row')
        if not isinstance(row.get('task_template'), str) or not row['task_template'].strip():
            raise ValueError('missing task template')
        if not row['name'].strip(): raise ValueError('missing case name')
        if type(row.get('seconds')) not in (int, float) or not math.isfinite(row['seconds']) or row['seconds'] < 0:
            raise ValueError('invalid duration')
        for key in ('verified_completion', 'false_success'):
            if type(row.get(key)) is not bool: raise ValueError(f'invalid {key}')
        for key in ('wrong_target_actions', 'duplicate_effects'):
            if type(row.get(key)) is not int or row[key] < 0: raise ValueError(f'invalid {key}')
        if row.get('status') == 'running': raise ValueError('unfinished measurement; finish or label interrupted first')
    return report


def comparable(reports):
    first = reports[0]
    for report in reports[1:]:
        for key in ('fixture_sha256', 'browser', 'mode', 'cancellation_experiment'):
            if report.get(key) != first.get(key): raise ValueError(f'cannot compare different {key}')
        names = sorted((row['name'], row.get('task_template')) for row in report['results'])
        expected = sorted((row['name'], row.get('task_template')) for row in first['results'])
        if names != expected: raise ValueError('case templates or repetition counts differ; rerun the same cases')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports', type=Path, nargs='+')
    args = parser.parse_args()
    try:
        reports = [load_report(path) for path in args.reports]
        comparable(reports)
    except (OSError, ValueError, TypeError, KeyError) as error: parser.error(str(error))
    result = []
    for path, report in zip(args.reports, reports):
        result.append({'source': str(path), 'label': report.get('label'), 'provider': report.get('provider'),
                       'measurement_origin': report.get('measurement_origin', 'clinqy-local-fixture'),
                       'environment': report.get('environment'), 'summary': summary(report['results']),
                       'by_case': {name: summary([row for row in report['results'] if row['name'] == name])
                                   for name in sorted({row['name'] for row in report['results']})}})
    print(json.dumps({'comparisons': result, 'note': 'Environment differences are shown, not normalized. Imported evidence is not independently audited by this command.'}, indent=2))
    return 0


if __name__ == '__main__': raise SystemExit(main())
