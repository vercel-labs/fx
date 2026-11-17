"""Prototype budget maintenance, not an fx implementation.

The caller supplies a manifest of sessions (id, oldest capture time, active,
stores and refs). Maintenance runs with no capture writers. An append-only
journal outside the stores records eviction before refs are removed. Failure
stops maintenance; admission remains blocked while usage exceeds the budget.
"""
import json
import os
from pathlib import Path
import subprocess
import sys


def candidates(sessions):
    """Oldest first, deterministic ties; active sessions are never candidates."""
    return sorted((s for s in sessions if not s['active']),
                  key=lambda s: (s['oldest'], s['id']))


def usage(stores):
    # Allocated bytes, including indexes, packs and temporary metadata.
    return sum(int(subprocess.check_output(['/usr/bin/du', '-sk', str(p)])
                   .split()[0]) * 1024 for p in stores)


def maintain(sessions, limit, journal):
    stores = sorted({item['store'] for s in sessions for item in s['refs']})
    evicted = []
    for session in candidates(sessions):
        if usage(stores) <= limit:
            break
        # This journal is the prototype's observable eviction record; fx must
        # define its profile-owned equivalent without writing inactive logs.
        with open(journal, 'a') as f:
            f.write(json.dumps({'session': session['id'], 'reason': 'budget'}) + '\n')
            f.flush()
            os.fsync(f.fileno())
        touched = set()
        for item in session['refs']:
            store, ref = item['store'], item['ref']
            subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null',
                            '-c', 'core.logAllRefUpdates=false',
                            f'--git-dir={store}', 'update-ref', '-d', ref], check=True)
            touched.add(store)
        for store in sorted(touched):
            subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null',
                            f'--git-dir={store}', 'gc', '--quiet',
                            '--prune=1.hour.ago'], check=True)
        evicted.append(session['id'])
    used = usage(stores)
    return {'evicted': evicted, 'used': used, 'admit': used <= limit}


if __name__ == '__main__':
    manifest, limit, journal = sys.argv[1:]
    print(json.dumps(maintain(json.loads(Path(manifest).read_text()), int(limit), journal)))
