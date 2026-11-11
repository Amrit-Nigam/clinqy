#!/usr/bin/env python3
"""Run identical local cases sequentially across explicitly selected Clinqy providers."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from run import PROVIDERS, save_results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', action='append', choices=PROVIDERS, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args, remaining = parser.parse_known_args()
    if any(flag in remaining for flag in ('--out', '--provider')):
        parser.error('output and providers are controlled by the matrix')
    args.out.mkdir(parents=True, exist_ok=True)
    results = []
    for index, provider in enumerate(dict.fromkeys(args.provider)):
        target = args.out / f'{index + 1:02}-{provider}.json'
        command = [sys.executable, str(Path(__file__).with_name('run.py')), '--provider', provider,
                   '--out', str(target), *remaining]
        status = subprocess.run(command).returncode
        item = {'provider': provider, 'exit_code': status, 'result': str(target), 'summary': None}
        try:
            report = json.loads(target.read_text())
            item['summary'] = report.get('summary')
            unsafe_to_continue = any(row.get('cancellation_confirmed') is False for row in report.get('results', []))
        except (OSError, ValueError):
            unsafe_to_continue = True
        results.append(item)
        save_results(args.out / 'matrix.json', {'runs': results})
        # Never launch another provider while an earlier owned task may still be executing.
        if status < 0 or unsafe_to_continue: break
    return 0 if len(results) == len(set(args.provider)) and all(row['exit_code'] == 0 for row in results) else 1


if __name__ == '__main__': raise SystemExit(main())
