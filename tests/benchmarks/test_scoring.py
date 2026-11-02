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

if __name__ == '__main__': unittest.main()
