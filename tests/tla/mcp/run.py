#!/usr/bin/env python3
"""Run TLC checks for the MCP engine models in this folder.

Modes:
  list      show the models in spec/catalog.json
  check     exhaustive TLC run of each model (smoke or stress preset)
  mutate    run every planted bug in <Module>.mutants.json
  simulate  seeded random simulation (SAMPLED, never counted as PASS)
  gate      for a unit: smoke, stress if present, and every planted bug

Exit codes: 0 every selected run passed (PASS, SAMPLED, CAUGHT), 1 a run failed,
2 usage or tooling error. Results go to <evidence-dir>/<unit>/tlc/<UTC>-<id>/, by
default in a new private folder under the system temp folder.
"""
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
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
PASS_MARKER = 'Model checking completed. No error has been found.'
SAFETY_VIOLATION_EXIT = 12
LIVENESS_VIOLATION_EXIT = 13
LIVENESS_MARKER = 'Temporal properties were violated'


class ToolingError(Exception):
    pass


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def tree_hash(root=ROOT):
    """Same value as `tools/build.sh hash`: sha256 over sorted `<sha>  <path>` lines."""
    files = []
    for top in ('src/mcp', 'cli'):
        base = root / top
        if base.is_dir():
            files += [p.relative_to(root).as_posix() for p in base.rglob('*.zig') if p.is_file()]
    lines = ''.join(f'{sha256(root / f)}  {f}\n' for f in sorted(files))
    return hashlib.sha256(lines.encode()).hexdigest()


def find_java():
    candidates = [os.environ.get('JAVA_BIN'),
                  str(Path(os.environ['JAVA_HOME']) / 'bin/java') if os.environ.get('JAVA_HOME') else None,
                  '/opt/homebrew/opt/openjdk/bin/java', shutil.which('java')]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            probe = subprocess.run([candidate, '-version'], capture_output=True, text=True)
            if probe.returncode == 0:
                return candidate, (probe.stderr + probe.stdout).strip()
    raise ToolingError('no working Java runtime; set JAVA_BIN or JAVA_HOME')


def pinned_jar():
    """tla2tools.jar from TLA2TOOLS_JAR or ~/.local/share/tla, as ../README.md says."""
    jar = Path(os.environ.get('TLA2TOOLS_JAR', str(Path.home() / '.local/share/tla/tla2tools.jar'))).resolve()
    if not jar.is_file():
        raise ToolingError(f'missing {jar} (set TLA2TOOLS_JAR)')
    return jar, {'sha256': sha256(jar)}


def statistics(output):
    result = {}
    match = re.search(r'([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue', output)
    if match:
        result.update(zip(('generated', 'distinct', 'queued'), (int(x.replace(',', '')) for x in match.groups())))
    depth = re.search(r'depth of the complete state graph search is (\d+)', output)
    if depth:
        result['depth'] = int(depth.group(1))
    return result


def classify(returncode, output, mode, mutant=None):
    if mutant and mutant.get('invariant'):
        caught = returncode == SAFETY_VIOLATION_EXIT and f"Invariant {mutant['invariant']} is violated" in output
        return 'CAUGHT' if caught else 'NOT_CAUGHT'
    if mutant and mutant.get('property'):
        # TLC does not name the temporal property it violated, so the run's
        # config keeps only that one property (keep_property). An action
        # property ([][A]_v, U12's Isolation) is named when it breaks.
        caught = returncode == LIVENESS_VIOLATION_EXIT and (LIVENESS_MARKER in output or f"Action property {mutant['property']} is violated" in output)
        return 'CAUGHT' if caught else 'NOT_CAUGHT'
    if returncode != 0 or 'Error:' in output or 'Fatal errors' in output:
        return 'FAIL'
    if mode == 'simulate':
        sampled = 'Running Random Simulation with seed' in output and 'Finished in' in output
        return 'SAMPLED' if sampled else 'FAIL'
    if PASS_MARKER in output and statistics(output).get('queued') == 0:
        return 'PASS'
    return 'FAIL'


def load_catalog(spec_dir):
    path = spec_dir / 'catalog.json'
    if not path.is_file():
        raise ToolingError(f'missing {path}')
    entries = json.loads(path.read_text())
    for entry in entries:
        module = entry['module']
        for needed in (module + '.tla', module + '.cfg'):
            if not (spec_dir / needed).is_file():
                raise ToolingError(f'catalog entry {module}: missing {spec_dir / needed}')
        if not re.fullmatch(r'U\d\d', entry.get('unit', '')):
            raise ToolingError(f'catalog entry {module}: unit must look like U02')
    return entries


def load_mutants(spec_dir, module):
    path = spec_dir / (module + '.mutants.json')
    if not path.is_file():
        return []
    mutants = json.loads(path.read_text())
    for number, mutant in enumerate(mutants, 1):
        for field in ('description', 'old', 'new'):
            if not mutant.get(field):
                raise ToolingError(f'{path.name} entry {number}: missing {field}')
        if bool(mutant.get('invariant')) == bool(mutant.get('property')):
            raise ToolingError(f'{path.name} entry {number}: name exactly one of invariant or property')
        if mutant.get('property'):
            declared = config_properties(spec_dir / (module + '.cfg'))
            if mutant['property'] not in declared:
                raise ToolingError(
                    f"{path.name} entry {number}: {module}.cfg doesn't declare PROPERTY {mutant['property']} "
                    f"(found {declared})")
    return mutants


def config_properties(cfg_path):
    """Names listed under PROPERTY or PROPERTIES in a TLC config."""
    names, collecting = [], False
    for raw in cfg_path.read_text().splitlines():
        line = raw.split('\\*')[0].strip()
        if not line:
            continue
        words = line.split()
        if words[0] in ('PROPERTY', 'PROPERTIES'):
            collecting = True
            names += words[1:]
        elif words[0].isupper():
            collecting = False
        elif collecting:
            names += words
    return names


def keep_property(cfg_text, name):
    """The config with only `name` left under PROPERTY, so a liveness failure is that property's."""
    kept, collecting = [], False
    for raw in cfg_text.splitlines():
        words = raw.split('\\*')[0].split()
        if words and words[0] in ('PROPERTY', 'PROPERTIES'):
            collecting = True
            continue
        if collecting and (not words or not words[0].isupper()):
            continue
        collecting = False
        kept.append(raw)
    return '\n'.join(kept + [f'PROPERTY {name}']) + '\n'


def config_for(spec_dir, module, preset):
    if preset == 'stress':
        stress = module + '.stress.cfg'
        return stress if (spec_dir / stress).is_file() else None
    return module + '.cfg'


def run_one(ctx, entry, mode, preset, mutant=None):
    spec_dir, args = ctx['spec_dir'], ctx['args']
    module = entry['module']
    config = config_for(spec_dir, module, preset)
    label = module + ('' if preset == 'smoke' else '-' + preset) + ('' if mutant is None else f"-mutant-{mutant['number']}")
    work = ctx['reports'][entry['unit']] / label
    (work / 'tmp').mkdir(parents=True)
    for path in spec_dir.iterdir():
        if path.is_file() and path.suffix in ('.tla', '.cfg'):
            shutil.copyfile(path, work / path.name)
    checked = work / (module + '.tla')
    if mutant:
        text = checked.read_text()
        count = text.count(mutant['old'])
        if count != 1:
            raise ToolingError(f"{module} mutant {mutant['number']}: 'old' text matches {count} times, needs exactly 1")
        checked.write_text(text.replace(mutant['old'], mutant['new'], 1))
        if mutant.get('property'):
            cfg = work / config
            cfg.write_text(keep_property(cfg.read_text(), mutant['property']))
    command = [ctx['java'], f'-Xmx{args.heap}', '-XX:+UseParallelGC', f'-Djava.io.tmpdir={work / "tmp"}',
               '-cp', str(ctx['jar']), 'tlc2.TLC', '-workers', str(args.workers), '-metadir', str(work / 'states'),
               '-config', config, '-fp', str(args.fp), '-coverage', '1']
    if mode == 'simulate':
        command += ['-simulate', f'num={args.traces}', '-seed', str(args.seed), '-depth', str(args.depth)]
    command.append(module + '.tla')
    start = datetime.now(timezone.utc)
    with (work / 'tlc.log').open('w') as log:
        proc = subprocess.run(command, cwd=work, stdout=log, stderr=subprocess.STDOUT)
    output = (work / 'tlc.log').read_text(errors='replace')
    result = {
        'unit': entry['unit'], 'module': module, 'mode': mode, 'preset': preset, 'label': label,
        'command': command, 'cwd': str(work), 'started_at': start.isoformat(),
        'seconds': round((datetime.now(timezone.utc) - start).total_seconds(), 3),
        'exit_code': proc.returncode,
        'model_sha256': sha256(spec_dir / (module + '.tla')), 'checked_model_sha256': sha256(checked),
        'config_sha256': sha256(work / config), 'jar_sha256': ctx['jar_sha256'],
        'result': classify(proc.returncode, output, mode, mutant),
        'statistics': statistics(output),
    }
    if mutant:
        result['mutant'] = mutant
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    shutil.rmtree(work / 'states', ignore_errors=True)
    print(f"{result['result']:10} {entry['unit']} {label:34} exit={proc.returncode} {result['statistics']}", flush=True)
    return result


def plan_runs(entries, args, spec_dir):
    runs = []
    for entry in entries:
        module = entry['module']
        if args.mode in ('check', 'simulate'):
            if config_for(spec_dir, module, args.preset) is None:
                raise ToolingError(f'{module} has no {args.preset} config')
            runs.append((entry, args.mode, args.preset, None))
        elif args.mode == 'mutate':
            mutants = load_mutants(spec_dir, module)
            if not mutants:
                raise ToolingError(f'{module} has no planted bugs in {module}.mutants.json')
            runs += [(entry, 'check', 'smoke', {**m, 'number': n}) for n, m in enumerate(mutants, 1)]
        elif args.mode == 'gate':
            mutants = load_mutants(spec_dir, module)
            if not mutants:
                raise ToolingError(f'gate for {module} needs at least one planted bug')
            runs.append((entry, 'check', 'smoke', None))
            if config_for(spec_dir, module, 'stress'):
                runs.append((entry, 'check', 'stress', None))
            runs += [(entry, 'check', 'smoke', {**m, 'number': n}) for n, m in enumerate(mutants, 1)]
    return runs


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('mode', choices=('list', 'check', 'mutate', 'simulate', 'gate'))
    parser.add_argument('--unit', nargs='+', help='select by unit, for example U02')
    parser.add_argument('--model', nargs='+', help='select by module name')
    parser.add_argument('--preset', choices=('smoke', 'stress'), default='smoke')
    parser.add_argument('--workers', type=int, default=1)
    parser.add_argument('--heap', default='512m')
    parser.add_argument('--fp', type=int, default=0)
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--traces', type=int, default=1000)
    parser.add_argument('--depth', type=int, default=100)
    parser.add_argument('--spec-dir', default=str(HERE))
    parser.add_argument('--evidence-dir', default=None)
    args = parser.parse_args(argv)
    if args.workers < 1 or args.traces < 1 or args.depth < 1 or not 0 <= args.fp <= 63:
        parser.error('workers, traces and depth must be positive; fp must be 0..63')

    spec_dir = Path(args.spec_dir).resolve()
    entries = load_catalog(spec_dir)
    if args.unit:
        entries = [e for e in entries if e['unit'] in args.unit]
        if set(args.unit) - {e['unit'] for e in entries}:
            parser.error('unknown unit selection')
    if args.model:
        entries = [e for e in entries if e['module'] in args.model]
        if set(args.model) - {e['module'] for e in entries}:
            parser.error('unknown model selection')
    if not entries:
        parser.error('no models selected')
    if args.mode == 'list':
        for entry in entries:
            mutants = len(load_mutants(spec_dir, entry['module']))
            stress = 'yes' if config_for(spec_dir, entry['module'], 'stress') else 'no'
            print(f"{entry['unit']} {entry['module']:20} stress={stress} planted_bugs={mutants}")
        return 0

    runs = plan_runs(entries, args, spec_dir)
    java, java_version = find_java()
    jar, pin = pinned_jar()
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    # By default a new private folder (mkdtemp), so another user cannot plant
    # a file or link where a log will be written.
    evidence = Path(args.evidence_dir or tempfile.mkdtemp(prefix='fx-tla-mcp-')).resolve()
    reports = {}
    for unit in sorted({e['unit'] for e, _, _, _ in runs}):
        reports[unit] = evidence / unit / 'tlc' / run_id
        reports[unit].mkdir(parents=True)
        (reports[unit] / 'environment.json').write_text(json.dumps({
            'run_id': run_id, 'java': java, 'java_version': java_version, 'toolchain': pin,
            'arguments': vars(args), 'source_tree_sha256': tree_hash(),
            'spec_dir': str(spec_dir),
        }, indent=2) + '\n')
    ctx = {'args': args, 'spec_dir': spec_dir, 'java': java, 'jar': jar, 'jar_sha256': sha256(jar), 'reports': reports}
    results = []
    try:
        for entry, mode, preset, mutant in runs:
            results.append(run_one(ctx, entry, mode, preset, mutant))
    finally:
        for unit, report in reports.items():
            mine = [r for r in results if r['unit'] == unit]
            (report / 'summary.json').write_text(json.dumps(mine, indent=2) + '\n')
            print(f'Summary: {report / "summary.json"}', flush=True)
    complete = len(results) == len(runs)
    return 0 if complete and all(r['result'] in ('PASS', 'SAMPLED', 'CAUGHT') for r in results) else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ToolingError, OSError, subprocess.SubprocessError, json.JSONDecodeError, KeyError) as error:
        print(f'run.py: tooling error: {error}', file=sys.stderr)
        sys.exit(2)
