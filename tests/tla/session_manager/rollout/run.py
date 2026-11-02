#!/usr/bin/env python3
"""Run bounded TLC checks of the session rollout models in catalog.json.

Modes: list, check (smoke or --preset stress), simulate, and mutate (every
planted bug in a model's mutants.json must be caught). Reports go to a fresh
folder under the system temp folder."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent


def find_java():
    candidates = [os.environ.get('JAVA_BIN'),
                  str(Path(os.environ['JAVA_HOME']) / 'bin/java') if os.environ.get('JAVA_HOME') else None,
                  '/opt/homebrew/opt/openjdk/bin/java', '/usr/local/opt/openjdk/bin/java', shutil.which('java')]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            probe = subprocess.run([candidate, '-version'], capture_output=True, text=True)
            if probe.returncode == 0:
                return candidate, (probe.stderr + probe.stdout).strip()
    raise RuntimeError('No working Java runtime. Set JAVA_BIN or JAVA_HOME to a JRE/JDK 11+ runtime.')


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def classify(returncode, output, mode, expected=None):
    if expected:
        needle = f'Invariant {expected} is violated'
        return 'CAUGHT' if returncode != 0 and needle in output else 'NOT_CAUGHT'
    if returncode != 0 or 'Error:' in output or 'Fatal errors' in output:
        return 'FAIL'
    if mode == 'simulate':
        return 'SAMPLED' if 'Running Random Simulation with seed' in output and re.search(r'Progress: [\d,]+ states checked\.', output) and 'Finished in' in output else 'FAIL'
    return 'PASS' if 'Model checking completed. No error has been found.' in output else 'FAIL'


def statistics(output):
    match = re.search(r'([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue', output)
    result = {}
    if match:
        result.update(zip(('generated', 'distinct', 'queued'), (int(x.replace(',', '')) for x in match.groups())))
    depth = re.search(r'depth of the complete state graph search is (\d+)', output)
    if depth:
        result['depth'] = int(depth.group(1))
    return result


def build_command(java, jar, work, model, config, args, historical=False):
    command = [java, f'-Xmx{args.heap}', '-XX:+UseParallelGC', f'-Djava.io.tmpdir={work / "tmp"}',
               '-cp', str(jar), 'tlc2.TLC', '-workers', str(args.workers), '-metadir', str(work / 'states'),
               '-config', config, '-fp', str(args.fp), '-coverage', '1']
    if historical:
        command.append('-deadlock')
    if args.mode == 'simulate':
        command += ['-simulate', f'num={args.traces}', '-seed', str(args.seed), '-depth', str(args.depth)]
    return command + [model + '.tla']


def execute(entry, args, java, jar, report, mutant=None):
    module = entry['module']
    label = module if mutant is None else module + '-mutant-' + str(mutant['number'])
    work = report / label
    (work / 'tmp').mkdir(parents=True)
    source = ROOT / entry['directory']
    for path in source.iterdir():
        if path.is_file() and path.suffix in ('.tla', '.cfg'):
            shutil.copyfile(path, work / path.name)
    original = source / (module + '.tla')
    config = module + ('.stress.cfg' if args.preset == 'stress' and not entry.get('historical') else '.cfg')
    if mutant:
        path = work / (module + '.tla')
        text = path.read_text()
        if text.count(mutant['old']) != 1:
            raise RuntimeError(f'Mutation does not match exactly once: {label}')
        path.write_text(text.replace(mutant['old'], mutant['new'], 1))
    command = build_command(java, jar, work, module, config, args, entry.get('historical', False))
    start = datetime.now(timezone.utc)
    with (work / 'tlc.log').open('w') as log:
        proc = subprocess.run(command, cwd=work, stdout=log, stderr=subprocess.STDOUT)
    output = (work / 'tlc.log').read_text(errors='replace')
    result = {'module': module, 'pr': entry.get('pr'), 'preset': args.preset, 'mode': args.mode,
              'historical': entry.get('historical', False), 'command': command, 'cwd': str(work),
              'started_at': start.isoformat(), 'seconds': (datetime.now(timezone.utc) - start).total_seconds(),
              'exit_code': proc.returncode, 'model_sha256': sha256(original),
              'checked_model_sha256': sha256(work / (module + '.tla')),
              'config_sha256': sha256(work / config), 'jar_sha256': sha256(jar),
              'result': classify(proc.returncode, output, args.mode, mutant['invariant'] if mutant else None),
              'statistics': statistics(output), 'log': str(work / 'tlc.log')}
    if mutant:
        result['mutation'] = mutant
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"{result['result']:10} {label:30} exit={proc.returncode} {result['statistics']}", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('list', 'check', 'simulate', 'mutate', 'historical'))
    parser.add_argument('--pr', nargs='+', type=int)
    parser.add_argument('--model', nargs='+')
    parser.add_argument('--preset', choices=('smoke', 'stress'), default='smoke')
    parser.add_argument('--workers', type=int, default=1)
    parser.add_argument('--heap', default='512m')
    parser.add_argument('--fp', type=int, default=0)
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--traces', type=int, default=1000)
    parser.add_argument('--depth', type=int, default=100)
    args = parser.parse_args()
    if args.workers < 1 or args.traces < 1 or args.depth < 1 or not 0 <= args.fp <= 63:
        parser.error('workers, traces, depth must be positive; fp must be 0..63')
    catalog = json.loads((ROOT / 'catalog.json').read_text())
    entries = [e for e in catalog if bool(e.get('historical')) == (args.mode == 'historical')]
    if args.pr:
        entries = [e for e in entries if e.get('pr') in args.pr]
        if set(args.pr) - {e.get('pr') for e in entries}:
            parser.error('Unknown or unavailable PR selection')
    if args.model:
        entries = [e for e in entries if e['module'] in args.model]
        if set(args.model) - {e['module'] for e in entries}:
            parser.error('Unknown model selection')
    if not entries:
        parser.error('No models selected')
    if args.mode == 'list':
        for entry in entries:
            print(f"PR {entry['pr']}: {entry['module']} ({entry['directory']})")
        return 0
    java, version = find_java()
    jar = Path(os.environ.get('TLA2TOOLS_JAR', str(Path.home() / '.local/share/tla/tla2tools.jar'))).resolve()
    if not jar.is_file():
        raise RuntimeError(f'missing {jar} (set TLA2TOOLS_JAR)')
    pin = {'sha256': sha256(jar)}
    # A new private folder (mkdtemp), so another user cannot plant a file or
    # link where a report will be written.
    report = Path(tempfile.mkdtemp(prefix='fx-tla-session-rollout-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-'))
    (report / 'environment.json').write_text(json.dumps({'java': java, 'version': version,
        'arguments': vars(args),
        'toolchain': pin}, indent=2) + '\n')
    print(f'Reports: {report}', flush=True)
    results = []
    try:
        for entry in entries:
            if args.mode == 'mutate':
                mutations = json.loads((ROOT / entry['directory'] / 'mutants.json').read_text())
                selected = [m for m in mutations if m['module'] == entry['module']]
                if not selected:
                    raise RuntimeError(f'No mutants for {entry["module"]}')
                for number, mutant in enumerate(selected, 1):
                    results.append(execute(entry, args, java, jar, report, {**mutant, 'number': number}))
            else:
                results.append(execute(entry, args, java, jar, report))
    finally:
        (report / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'Summary: {report / "summary.json"}')
    return 0 if results and all(r['result'] in ('PASS', 'SAMPLED', 'CAUGHT') for r in results) else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f'Tooling error: {error}', file=sys.stderr)
        sys.exit(2)
