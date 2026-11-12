"""Focused tests of prototype budget selection and real Git reclamation."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import budget


class BudgetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fx-budget-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        env = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null',
                   GIT_CONFIG_NOSYSTEM='1', HOME=str(self.root))
        self.env = patch.dict(os.environ, env, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.journal = self.root / 'evictions.jsonl'
        self.stores = []

    def git(self, store, *args, data=None):
        return subprocess.check_output(
            ['/usr/bin/git', '-c', 'user.name=fixture',
             '-c', 'user.email=fixture@example.invalid', f'--git-dir={store}', *args],
            input=data, stderr=subprocess.DEVNULL).strip().decode()

    def store(self):
        path = self.root / f'store{len(self.stores)}'
        subprocess.run(['/usr/bin/git', 'init', '--quiet', '--bare', '--template=', str(path)], check=True)
        self.stores.append(path)
        return path

    def capture(self, store, name, active=False, oldest=0):
        ref = f'refs/fx/sessions/{name}'
        oid = self.git(store, 'hash-object', '-w', '--stdin', data=os.urandom(300000))
        tree = self.git(store, 'mktree', data=f'100644 blob {oid}\tf\n'.encode())
        commit = self.git(store, 'commit-tree', tree, '-m', name)
        self.git(store, 'update-ref', ref, commit)
        # Make objects old enough for Git's grace period. Recent objects have
        # a separate test; production never changes their timestamps.
        for p in (store / 'objects').glob('??/*'):
            os.utime(p, (1577836800, 1577836800))
        session = {'id': name, 'oldest': oldest, 'active': active,
                   'refs': [{'store': str(store), 'ref': ref}]}
        return session, oid

    def exists(self, store, oid):
        return subprocess.run(['/usr/bin/git', f'--git-dir={store}',
                               'cat-file', '-e', oid], stderr=subprocess.DEVNULL).returncode == 0

    def test_order_is_oldest_first_and_skips_active(self):
        rows = [{'id': 'z', 'oldest': 1, 'active': False},
                {'id': 'active', 'oldest': 0, 'active': True},
                {'id': 'a', 'oldest': 1, 'active': False},
                {'id': 'new', 'oldest': 2, 'active': False}]
        self.assertEqual([s['id'] for s in budget.candidates(rows)], ['a', 'z', 'new'])

    def test_evicts_only_oldest_and_remeasures_real_disk(self):
        st = self.store()
        old, old_blob = self.capture(st, 'old', oldest=1)
        new, new_blob = self.capture(st, 'new', oldest=2)
        active, active_blob = self.capture(st, 'active', active=True, oldest=0)
        before = budget.usage([st])
        result = budget.maintain([new, active, old], before - 200000, self.journal)
        self.assertEqual(result['evicted'], ['old'])
        self.assertTrue(result['admit'])
        self.assertFalse(self.exists(st, old_blob))
        self.assertTrue(self.exists(st, new_blob))
        self.assertTrue(self.exists(st, active_blob))
        self.assertGreater(before - result['used'], 200000)
        self.assertEqual(json.loads(self.journal.read_text()), {'session': 'old', 'reason': 'budget'})

    def test_does_nothing_within_budget(self):
        st = self.store()
        session, _ = self.capture(st, 's')
        result = budget.maintain([session], budget.usage([st]), self.journal)
        self.assertEqual(result['evicted'], [])
        self.assertFalse(self.journal.exists())

    def test_active_sessions_cannot_be_evicted_even_if_over_budget(self):
        st = self.store()
        session, blob = self.capture(st, 'active', active=True)
        result = budget.maintain([session], 1, self.journal)
        self.assertEqual(result['evicted'], [])
        self.assertFalse(result['admit'])
        self.assertTrue(self.exists(st, blob))

    def test_evicts_session_across_all_its_repositories(self):
        a, b = self.store(), self.store()
        old, blob_a = self.capture(a, 'old')
        other, blob_b = self.capture(b, 'old')
        old['refs'] += other['refs']
        result = budget.maintain([old], 1, self.journal)
        self.assertEqual(result['evicted'], ['old'])
        self.assertFalse(self.exists(a, blob_a))
        self.assertFalse(self.exists(b, blob_b))
        self.assertFalse(result['admit'])  # repository overhead still occupies space

    def test_recent_evicted_objects_respect_grace_and_block_admission(self):
        st = self.store()
        session, blob = self.capture(st, 'recent')
        for p in (st / 'objects').glob('??/*'):
            os.utime(p, None)
        result = budget.maintain([session], 1, self.journal)
        self.assertFalse(result['admit'])
        self.assertTrue(self.exists(st, blob))


if __name__ == '__main__':
    unittest.main()
