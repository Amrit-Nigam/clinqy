"""Deferred regressions for evaluation infrastructure. Do not mistake these for live-browser results."""
import json
import tempfile
import unittest
from pathlib import Path

from compare import comparable, load_report
from import_results import normalize
from run import CASES, SCHEMA_VERSION, file_matches, finite_metrics, score


class EvidenceTests(unittest.TestCase):
    def test_range_case_requires_fixture_value_and_one_change(self):
        _, task, expected = next(case for case in CASES if case[0] == 'range')
        self.assertIn('set_state', task)
        self.assertTrue(score(expected, {'range_value': 65, 'range_changes': 1, 'submitted': 0}, True)['verified_completion'])
        for state in ({'range_value': 25, 'range_changes': 0, 'submitted': 0},
                      {'range_value': 65, 'range_changes': 0, 'submitted': 0},
                      {'range_value': 65, 'range_changes': 2, 'submitted': 0},
                      {'range_value': '65', 'range_changes': 1, 'submitted': 0}):
            self.assertTrue(score(expected, state, True)['false_success'])

    def test_false_verdict_cannot_override_fixture(self):
        self.assertTrue(score({'accepted': True}, {'accepted': False}, True)['false_success'])
        self.assertFalse(score({'accepted': True}, {'accepted': True, 'submitted': 2}, True)['verified_completion'])

    def test_malformed_counter_is_not_evidence(self):
        self.assertFalse(score({'accepted': True}, {'accepted': True, 'saved': '1'}, True)['verified_completion'])
        self.assertFalse(score({'accepted': True}, {'accepted': True, 'wrong': False}, True)['verified_completion'])

    def test_download_requires_exact_regular_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.txt'
            self.assertFalse(file_matches(path, b'complete'))
            path.write_bytes(b'partial')
            self.assertFalse(file_matches(path, b'complete'))
            path.write_bytes(b'complete')
            self.assertTrue(file_matches(path, b'complete'))
            link = Path(directory) / 'link'; link.symlink_to(path)
            self.assertFalse(file_matches(link, b'complete'))

    def test_only_finite_measured_metrics(self):
        self.assertEqual(finite_metrics({'phaseMilliseconds': {'model': 10, 'bad': float('nan'), 'negative': -1, 'boolean': True}}), {'model': 10})
        self.assertEqual(finite_metrics(None), {})

    def test_external_import_recomputes_verdict(self):
        result = normalize({'tool': 'External runner', 'browser': 'Google Chrome', 'mode': 'background', 'fixture_sha256': 'a' * 64, 'runs': [
            {'name': 'name', 'seconds': 1, 'reported_success': True, 'fixture_state': {'name': 'wrong', 'wrong': 0, 'submitted': 0}}]})
        self.assertFalse(result['results'][0]['verified_completion'])
        self.assertTrue(result['results'][0]['false_success'])

    def test_missing_comparison_identity_is_rejected(self):
        report = {'schema_version': SCHEMA_VERSION, 'fixture_sha256': 'a' * 64,
                  'browser': 'Google Chrome', 'mode': 'background', 'results': [
                      {'name': 'name', 'task_template': 'Fill Name', 'seconds': 1,
                       'verified_completion': True, 'false_success': False,
                       'wrong_target_actions': 0, 'duplicate_effects': 0}]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            for key in ('browser', 'mode', 'fixture_sha256'):
                malformed = dict(report); malformed.pop(key)
                path.write_text(json.dumps(malformed))
                with self.assertRaises(ValueError): load_report(path)
            report['results'][0].pop('task_template')
            path.write_text(json.dumps(report))
            with self.assertRaises(ValueError): load_report(path)

    def test_comparison_refuses_different_work(self):
        common = {'fixture_sha256': 'a' * 64, 'browser': 'Google Chrome', 'mode': 'background',
                  'results': [{'name': 'name', 'task_template': 'Fill Name'}]}
        with self.assertRaises(ValueError): comparable([common, dict(common, browser='Arc')])
        with self.assertRaises(ValueError): comparable([common, dict(common, results=[])])
        with self.assertRaises(ValueError): comparable([common, dict(common, fixture_sha256='b' * 64)])


if __name__ == '__main__': unittest.main()
