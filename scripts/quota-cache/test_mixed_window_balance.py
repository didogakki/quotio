import unittest
from datetime import datetime
from cpa_newapi_balance import mixed_window_metrics


def window(used, duration, reset):
    return {'used_percent': used, 'limit_window_seconds': duration, 'reset_at': reset}


def score(rate, now=1000):
    return mixed_window_metrics(rate, now, now, 5, 7200)[5]


class MixedWindowTests(unittest.TestCase):
    def test_weekly_only_has_no_short_window_penalty(self):
        weekly = window(20, 604800, 100000)
        self.assertEqual(score({'primary_window': weekly}), score({'primary_window': window(0, 18000, 5000), 'secondary_window': weekly}))

    def test_window_order_does_not_change_score(self):
        a, b = window(30, 18000, 5000), window(40, 604800, 100000)
        self.assertEqual(score({'primary_window': a, 'secondary_window': b}), score({'primary_window': b, 'secondary_window': a}))

    def test_exhaustion_in_either_window_zeroes_score(self):
        for short, weekly in [(100, 5), (5, 100)]:
            self.assertEqual(score({'primary_window': window(short, 18000, 5000), 'secondary_window': window(weekly, 604800, 100000)}), 0)
        self.assertEqual(score({'allowed': False, 'primary_window': window(0, 604800, 100000)}), 0)

    def test_short_headroom_monotonically_reduces_score(self):
        scores = [score({'primary_window': window(x, 18000, 5000), 'secondary_window': window(10, 604800, 100000)}) for x in (0, 20, 80, 95)]
        self.assertEqual(scores, sorted(scores, reverse=True))
        self.assertEqual(scores[-1], 0)

    def test_invalid_or_expired_data_aborts(self):
        for w in [window(True, 604800, 5000), window(0, 42, 5000), window(0, 604800, 1000), window(0, 18000, 5000), window(0, 604800, 'garbage')]:
            with self.assertRaises(ValueError): score({'primary_window': w})

    def test_absolute_expired_timestamp_never_uses_relative_fallback(self):
        w = window(0, 604800, 999); w['reset_after_seconds'] = 100000
        with self.assertRaises(ValueError): score({'primary_window': w})

    def test_relative_reset_stays_anchored(self):
        rate={'primary_window': {'used_percent': 0, 'limit_window_seconds': 604800, 'reset_after_seconds': 10000}}
        a=mixed_window_metrics(rate, 1100, 1000, 5, 7200)
        b=mixed_window_metrics(rate, 1200, 1000, 5, 7200)
        self.assertEqual(a[4], b[4]); self.assertEqual(a[3]-b[3], 100)

    def test_september15_weekly_budget_counterexample(self):
        def ts(s): return datetime.fromisoformat('2026-'+s+'+09:00').timestamp()
        now=ts('09-15T15:17:44')
        rows=[('plus-a',9,96,'09-15T18:30:13','09-19T17:09:45'),('plus-b',12,98,'09-15T17:37:05','09-19T17:09:45'),('business-a',29,5,'09-15T19:26:47','09-22T14:26:47'),('business-b',22,100,'09-15T18:29:55','09-19T17:10:59')]
        scores={name:score({'primary_window':window(short,18000,ts(sr)),'secondary_window':window(weekly,604800,ts(wr))},now) for name,short,weekly,sr,wr in rows}
        self.assertEqual(scores['plus-a']+scores['plus-b'],0)
        self.assertGreater(scores['business-a'],0)
        self.assertEqual(scores['business-b'],0)

    def test_duplicate_window_rejected(self):
        with self.assertRaises(ValueError): score({'primary_window':window(0,604800,5000),'secondary_window':window(0,604800,6000)})
