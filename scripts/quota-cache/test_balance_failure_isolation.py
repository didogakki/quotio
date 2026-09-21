"""A failed quota observation must not block healthy CPA account updates."""
import json
import unittest
from unittest.mock import patch
import cpa_newapi_balance as b
from test_cpa_newapi_balance import FakeManagementClient, FakeQR, _entry, _pool_config

NOW = 1700000000
CFG = {'scoring_policy': 'weekly_headroom_v1'}

def envelope(short=None):
    rate = {'primary_window': {'limit_window_seconds': 604800, 'used_percent': 20, 'reset_at': NOW+86400}}
    if short is not None:
        rate['secondary_window'] = {'limit_window_seconds': 18000, 'used_percent': short, 'reset_at': NOW+3600}
    return {'result': {'status_code': 200, 'body': json.dumps({'rate_limit': rate})}, 'fetched_at': NOW, 'stale': False}

class IsolationTests(unittest.TestCase):
    def collect(self, readings, weights):
        entries = [dict(_entry(str(i)), weight=w) for i,w in enumerate(weights)]
        def fetch(*args, **kwargs):
            value = readings[int(args[3])]
            if isinstance(value, Exception):
                raise value
            return value
        with patch.object(b.quota_cache_client, 'fetch', side_effect=fetch):
            return b.collect_pool(FakeQR(FakeManagementClient(entries)), _pool_config('http://localhost/cache'), {}, CFG, 5, now=NOW)

    def test_unknown_frozen_healthy_budget_transfers_to_weekly_only(self):
        for error in [b.quota_cache_client.QuotaCacheError('timeout'), {'result': {'status_code':401,'body':''},'fetched_at':NOW}, {'result':{'status_code':200,'body':'{}'},'fetched_at':NOW}]:
            with self.subTest(error=type(error).__name__):
                pool = self.collect([error, envelope(100), envelope()], [20,50,30])
                b.assign_account_weights({}, pool)
                changes = b.account_weight_changes({}, [pool])
                self.assertEqual(pool.failed_accounts, 1)
                self.assertEqual({x.account.auth_index:x.new_weight for x in changes}, {'1':0,'2':80})
                self.assertEqual(sum(a.target_weight for a in pool.accounts),80)

    def test_large_existing_weights_keep_a_feasible_healthy_budget(self):
        pool=self.collect([RuntimeError('failure'),envelope(),envelope()],[200,150,150])
        b.assign_account_weights({},pool)
        self.assertEqual(sum(a.target_weight for a in pool.accounts),300)

    def test_all_failed_produces_no_account_writes(self):
        pool=self.collect([RuntimeError('failure')],[40])
        b.assign_account_weights({},pool)
        self.assertEqual(b.account_weight_changes({},[pool]),[])
        self.assertEqual(pool.failed_accounts,1)

    def test_zero_healthy_budget_does_not_invent_recovery(self):
        pool=self.collect([RuntimeError('failure'),envelope()],[100,0])
        b.assign_account_weights({},pool)
        self.assertEqual(pool.accounts[0].target_weight,0)

    def test_recovered_reading_restores_full_normalization(self):
        pool=self.collect([envelope(),envelope(100)],[0,100])
        b.assign_account_weights({},pool)
        self.assertEqual(pool.failed_accounts,0)
        self.assertEqual([a.target_weight for a in pool.accounts],[100,0])

    def test_main_updates_healthy_pool_but_freezes_channels(self):
        failed=self.collect([RuntimeError('failure')],[100])
        healthy=self.collect([envelope(100),envelope()],[50,50]); healthy.name='business'
        config=dict(CFG, quota_recovery_module='fake',quota_recovery_config='fake')
        qr=FakeQR(FakeManagementClient([])); qr.load_config=lambda _: {'pools':[{'name':'plus'},{'name':'business'}]}
        with patch.object(b,'load_json',return_value=config), patch.object(b,'configure_logging'), patch.object(b,'load_quota_module',return_value=qr), patch.object(b,'collect_pool',side_effect=[failed,healthy]), patch.object(b,'get_routing_strategy',return_value='weighted-round-robin'), patch.object(b,'current_channel_weights',return_value={'plus':60,'business':40}), patch.object(b,'target_channel_weights') as targets, patch.object(b,'patch_account_weight') as write, patch.object(b,'verify_account_changes'), patch.object(b,'apply_channel_weights') as channels, patch('sys.argv',['balance','--config','fake','--apply']):
            self.assertEqual(b.main(),0)
            self.assertEqual(write.call_count,2)
            targets.assert_not_called(); channels.assert_not_called()

    def test_confirmed_auth_invalid_is_quarantined_and_healthy_account_gets_full_weight(self):
        error = b.quota_cache_client.QuotaCacheError(
            "quota-cache returned HTTP 503",
            http_status=503,
            failure_kind="auth_invalid",
            failure_status_code=401,
        )
        pool = self.collect([error, envelope()], [40, 60])
        b.assign_account_weights({}, pool)
        self.assertEqual(pool.failed_accounts, 0)
        self.assertEqual(pool.auth_invalid_accounts, 1)
        self.assertEqual([a.target_weight for a in pool.accounts], [0, 100])
        self.assertEqual(
            {change.account.auth_index: change.new_weight for change in b.account_weight_changes({}, [pool])},
            {"0": 0, "1": 100},
        )

    def test_weekly_four_percent_is_usable_when_reserve_is_omitted(self):
        low_weekly = {
            'result': {
                'status_code': 200,
                'body': json.dumps({'rate_limit': {
                    'primary_window': {
                        'limit_window_seconds': 604800,
                        'used_percent': 96,
                        'reset_at': NOW + 86400,
                    }
                }}),
            },
            'fetched_at': NOW,
            'stale': False,
        }
        pool = self.collect([envelope(100), low_weekly], [50, 0])
        b.assign_account_weights({}, pool)
        by_index = {a.auth_index: a for a in pool.accounts}
        self.assertGreater(by_index['1'].urgency_score, 0)
        self.assertEqual(by_index['1'].usable_remaining_percent, 4)
        self.assertEqual(by_index['1'].target_weight, 100)

if __name__ == '__main__': unittest.main()
