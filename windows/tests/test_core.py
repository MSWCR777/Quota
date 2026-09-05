import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from core import parse_snapshot, PendingKeys, Session


class CoreTests(unittest.TestCase):
    def payload(self):
        return {'accountId': 'fake', 'rateLimits': {'primary': {'usedPercent': 20,
            'windowDurationMins': 300, 'resetsAt': 1900000000}}}

    def test_missing_credits_are_not_zero(self):
        self.assertIsNone(parse_snapshot(self.payload())['credits'])

    def test_named_bucket_and_clamping(self):
        data=self.payload()
        bucket=data.pop('rateLimits')
        bucket['primary']['usedPercent']=110
        data['rateLimitsByLimitId']={'other': {}, 'codex': bucket}
        self.assertEqual(parse_snapshot(data)['windows'][0]['remaining'],0)
        data['rateLimitsByLimitId'].pop('codex')
        with self.assertRaises(ValueError):
            parse_snapshot(data)

    def test_reject_nonfinite(self):
        data=self.payload()
        data['rateLimits']['primary']['usedPercent']=float('nan')
        with self.assertRaises(ValueError):
            parse_snapshot(data)

    def test_persistent_retry_and_account_isolation(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'keys.json'
            store=PendingKeys(path)
            a=store.key('a')
            self.assertEqual(a,PendingKeys(path).key('a'))
            self.assertNotEqual(a,store.key('b'))
            store.resolve('a')
            self.assertNotEqual(a,store.key('a'))
            path.write_text('broken',encoding='utf-8')
            with self.assertRaises(ValueError):
                store.key('a')

    def test_jsonl_handshake_and_timeout(self):
        session=Session([sys.executable,str(Path(__file__).with_name('fake_server.py'))])
        try:
            result=session.request('account/rateLimits/read')
            self.assertEqual(parse_snapshot(result)['windows'][0]['remaining'],80)
            with self.assertRaises(TimeoutError):
                session.request('timeout',timeout=.1)
        finally:
            session.close()


if __name__=='__main__':
    unittest.main()
