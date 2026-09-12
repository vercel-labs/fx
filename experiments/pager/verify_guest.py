#!/usr/bin/env python3
"""Copy static build artifacts over SSH and verify them in a macOS guest."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import struct
import subprocess

from rewrite_macho import parse

ROOT = Path(__file__).resolve().parent


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ssh-host', required=True, help='user@guest-address')
    p.add_argument('--key', type=Path, required=True)
    p.add_argument('--known-hosts', type=Path, required=True)
    p.add_argument('--guest-root', default='/Users/admin/fx-pager')
    p.add_argument('--build-dir', type=Path, required=True, help='contains eager, demand and thread-demand directories')
    p.add_argument('--report', type=Path, required=True)
    a = p.parse_args()
    ssh = ['ssh', '-i', str(a.key), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
           '-o', 'StrictHostKeyChecking=yes', '-o', 'ForwardAgent=no',
           '-o', 'UserKnownHostsFile='+str(a.known_hosts), '-o', 'ConnectTimeout=10', a.ssh_host]
    def remote(command, data=None):
        return subprocess.run(ssh+[command],input=data,capture_output=True,timeout=180)
    def checked(command):
        r=remote(command)
        if r.returncode:
            raise RuntimeError(r.stderr.decode(errors='replace') or r.stdout.decode(errors='replace'))
        return r.stdout.decode()
    model=checked('/usr/sbin/sysctl -n hw.model').strip()
    if not model.startswith('VirtualMac'):
        raise SystemExit('refusing target: not a VirtualMac guest')
    root=shlex.quote(a.guest_root)
    checked('mkdir -p '+root+'/zig-out/bin')
    def upload(data, relative):
        target=shlex.quote(a.guest_root+'/'+relative)
        r=remote('cat > '+target+' && chmod 755 '+target,data)
        if r.returncode: raise RuntimeError(r.stderr.decode())
        actual=checked('/usr/bin/shasum -a 256 '+target).split()[0]
        if actual!=hashlib.sha256(data).hexdigest(): raise RuntimeError('guest artifact hash mismatch')
    result=dict(model=model,os=checked('sw_vers'),boot_before=checked('sysctl -n kern.boottime'),checks=[],artifacts={})
    a.report.parent.mkdir(parents=True,exist_ok=True)
    def save(): a.report.write_text(json.dumps(result,indent=2)+'\n')
    def run_check(name,command,expected=0,contains=None,tui=False):
        r=remote('cd '+root+' && '+command)
        try: d=json.loads(r.stdout)
        except ValueError: raise RuntimeError(name+': '+r.stderr.decode()+' '+r.stdout.decode(errors='replace'))
        records=[d] if tui else d['results']
        passed=all(x['returncode']==expected and (expected!=0 or not x['stderr']) and
                   (contains is None or contains in x.get('stdout',x.get('transcript',''))) for x in records)
        result['checks'].append(dict(name=name,passed=passed,evidence=d))
        save()
        print(name+(': passed' if passed else ': FAILED'),flush=True)
        if not passed: raise RuntimeError(name+' failed; see report')
    for name in ('guest_check.py','guest_tui_check.py'):
        upload((ROOT/name).read_bytes(),name)
    for mode in ('eager','demand'):
        binary=(a.build_dir/mode/'fx').read_bytes()
        result['artifacts'][mode]=json.loads((a.build_dir/mode/'build-report.json').read_text())
        upload(binary,'zig-out/bin/fx')
        run_check(mode+' version','python3 guest_check.py --repeat 20 -- ./zig-out/bin/fx -v')
        run_check(mode+' help','python3 guest_check.py -- ./zig-out/bin/fx help',contains='Usage:')
        run_check(mode+' status','python3 guest_check.py -- ./zig-out/bin/fx status --json')
        if mode=='demand': run_check('demand TUI','python3 guest_tui_check.py',contains='start a fresh session',tui=True)
    upload((a.build_dir/'thread-demand/fx').read_bytes(),'thread-fixture')
    result['artifacts']['threads']=json.loads((a.build_dir/'thread-demand/build-report.json').read_text())
    run_check('concurrent faults','python3 guest_check.py --repeat 20 -- ./thread-fixture',contains='concurrent cold-page calls passed')
    upload((a.build_dir/'write-demand/fx').read_bytes(),'write-fixture')
    result['artifacts']['write-fault']=json.loads((a.build_dir/'write-demand/build-report.json').read_text())
    run_check('write to executable page','python3 guest_check.py -- ./write-fixture',expected=88)
    # Mutations occur offline, followed by signing. Never execute them here.
    original=(a.build_dir/'demand/fx').read_bytes()
    segments=parse(original)[2]
    meta=next(s for s in segments if s['name']==b'__PGMETA')
    config=struct.unpack_from('<16Q',original,meta['fo'])
    for name,expected in (('bad-checksum',74),('denied-write',73)):
        bad=bytearray(original)
        if name=='bad-checksum':
            for i in range(config[8]):
                off=meta['fo']+config[9]-meta['va']+i*16+8
                struct.pack_into('<Q',bad,off,struct.unpack_from('<Q',bad,off)[0]^1)
        else:
            pos=32
            for cmd,raw in parse(original)[1]:
                if cmd==0x19 and raw[8:24].rstrip(b'\0')==b'__TEXT': struct.pack_into('<I',bad,pos+56,5)
                pos+=len(raw)
        path=a.build_dir/name
        path.write_bytes(bad)
        subprocess.run(['codesign','--force','--sign','-',str(path)],check=True,capture_output=True)
        upload(path.read_bytes(),name)
        run_check(name,'python3 guest_check.py -- ./'+name,expected=expected)
    result['boot_after']=checked('sysctl -n kern.boottime')
    result['passed']=result['boot_before']==result['boot_after'] and all(c['passed'] for c in result['checks'])
    save()
    if not result['passed']: raise SystemExit('guest restarted during checks')
    print('Guest verification passed; evidence: '+str(a.report))


if __name__=='__main__': main()
