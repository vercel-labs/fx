#!/usr/bin/env python3
"""Strict runtime-trace checking of real fx sessions against the session manager
trace wrappers in tests/tla/session_manager/trace/: each log's turns, its
children's work, a fork's copied lines (ForkLog), and the processes' wiring."""
import argparse
from datetime import datetime, timezone
import importlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
ARCHIVE = Path(__file__).resolve().parents[2] / 'session_manager/trace'
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'session_manager/rollout'))
from run import find_java, sha256  # noqa: E402
sys.path.insert(0, str(ARCHIVE))
saved = importlib.import_module('check_saved_logs')
wiring = importlib.import_module('check_wiring_traces')
MAX_EVIDENCE_BYTES = 64 * 1024 * 1024
VALID_ID = re.compile(r'(?!\.{1,2}\Z)[A-Za-z0-9._-]{1,160}\Z')


class Inconclusive(Exception):
    pass


def crc32c(data):
    crc = 0xffffffff
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82f63b78 if crc & 1 else 0)
    return crc ^ 0xffffffff


def checked_lines(data):
    if not data or not data.endswith(b'\n'):
        raise Inconclusive('empty log or incomplete final JSONL line')
    lines = []
    for position, raw in enumerate(data.splitlines(), 1):
        try:
            entry = json.loads(raw)
        except (ValueError, UnicodeDecodeError) as error:
            raise Inconclusive(f'unreadable JSON at line {position}: {error}') from error
        if not isinstance(entry, dict) or entry.get('seq') != position:
            raise Inconclusive(f'non-contiguous seq at line {position}')
        marker = raw.rfind(b',"crc":"')
        suffix = raw[marker:] if marker >= 0 else b''
        if not re.fullmatch(rb',"crc":"[0-9a-f]{8}"}', suffix):
            raise Inconclusive(f'noncanonical or missing CRC at line {position}')
        if crc32c(raw[:marker]) != int(entry['crc'], 16):
            raise Inconclusive(f'CRC32C mismatch at line {position}')
        lines.append(entry)
    if lines[0].get('kind') != 'session_created':
        raise Inconclusive('session_created header missing')
    return lines


def checked_wiring(text, processes):
    events = []
    for line in text.splitlines():
        if '[wiring]' not in line:
            continue
        match = wiring.LINE.fullmatch(line)
        if not match:
            raise Inconclusive('malformed wiring line')
        events.append((int(match.group(4)), match.group(1), match.group(2), match.group(3)))
    if not events:
        raise Inconclusive('no wiring events observed')
    outcomes = {}
    for process in processes:
        pid = process.get('pid')
        if not isinstance(pid, int) or pid <= 0 or pid in outcomes:
            raise Inconclusive('process outcomes require unique positive PIDs')
        code, signal = process.get('exitCode'), process.get('signal')
        if not ((isinstance(code, int) and signal is None) or (code is None and signal in ('SIGKILL', 'SIGTERM'))):
            raise Inconclusive('missing or unsupported observed process termination')
        outcomes[pid] = process
    if set(outcomes) != {event[0] for event in events}:
        raise Inconclusive('wiring process set does not equal observed process outcomes')
    for pid, outcome in outcomes.items():
        mine = [event for event in events if event[0] == pid]
        if mine[0][1] != 'StoreOpen':
            raise Inconclusive('startup StoreOpen missing; cannot infer startup')
        depth = 0
        for _, action, _, _ in mine:
            if action == 'StoreOpen':
                depth += 1
            elif action == 'StoreClose':
                depth -= 1
            if depth < 0:
                raise Inconclusive('store lifecycle nesting is malformed')
        if outcome['signal'] is None and (depth != 0 or mine[-1][1] != 'StoreClose'):
            raise Inconclusive('normal process exit lacks complete StoreClose evidence')
        if outcome['signal'] is not None and depth == 0:
            raise Inconclusive('crash case did not reach an open-store fault boundary')
    try:
        return wiring.steps_for(events)
    except wiring.Skip as error:
        raise Inconclusive(str(error)) from error


def trace_verdict(code, output, sentinel, expected):
    matches = [int(value) for value in re.findall(r'"matched_lines", (\d+)', output)]
    matched = max(matches, default=0)
    if code == 12 and f'Invariant {sentinel} is violated' in output and matched == expected and expected > 0:
        return 'ACCEPTED', matched
    if code == 0 and 'Model checking completed. No error has been found.' in output and matched < expected:
        return 'REJECTED', matched
    return 'TOOL_ERROR', matched


def aggregate(checks):
    verdicts = {check['verdict'] for check in checks}
    for verdict in ('TOOL_ERROR', 'INCONCLUSIVE', 'REJECTED'):
        if verdict in verdicts:
            return verdict
    return 'ACCEPTED' if checks and verdicts == {'ACCEPTED'} else 'INCONCLUSIVE'


class RetainedTLC:
    def __init__(self, report, java, jar):
        self.report, self.java, self.jar = report, java, jar
        self.expected = 0
        self.last = None
        self.sequence = 0

    def run(self, module, spec_files, generated, cfg, invariant='NotWritten'):
        self.sequence += 1
        work = self.report / 'tlc' / f'{self.sequence:03d}-{module}'
        (work / 'tmp').mkdir(parents=True)
        models = {}
        for source in map(Path, spec_files):
            shutil.copyfile(source, work / source.name)
            models[source.name] = sha256(source)
        for name, text in generated.items():
            (work / name).write_text(text)
        config = work / (module + '.cfg')
        config.write_text(cfg)
        command = [self.java, '-Xmx512m', '-XX:+UseParallelGC', f'-Djava.io.tmpdir={work / "tmp"}',
                   '-cp', str(self.jar), 'tlc2.TLC', '-workers', '1', '-deadlock',
                   '-metadir', str(work / 'states'), '-config', config.name, module]
        start = datetime.now(timezone.utc)
        with (work / 'tlc.log').open('w') as output:
            code = subprocess.run(command, cwd=work, stdout=output, stderr=subprocess.STDOUT).returncode
        output = (work / 'tlc.log').read_text(errors='replace')
        verdict, matched = trace_verdict(code, output, invariant, self.expected)
        self.last = {'verdict': verdict, 'model': module, 'matched': matched, 'expected': self.expected,
                     'exitCode': code, 'command': command, 'cwd': str(work), 'modelHashes': models,
                     'configHash': sha256(config), 'jarHash': sha256(self.jar),
                     'generatedHashes': {name: sha256(work / name) for name in generated},
                     'seconds': (datetime.now(timezone.utc) - start).total_seconds(),
                     'log': str(work / 'tlc.log')}
        (work / 'result.json').write_text(json.dumps(self.last, indent=2) + '\n')
        return verdict, matched


def read_regular(path):
    try:
        info = path.lstat()
    except OSError as error:
        raise Inconclusive(f'missing/unreadable evidence: {path.name}') from error
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_EVIDENCE_BYTES:
        raise Inconclusive('evidence must be a bounded regular file, not a symlink')
    try:
        return path.read_bytes()
    except OSError as error:
        raise Inconclusive(f'evidence read failed: {error}') from error


def verify(request, report):
    ids = request.get('sessionIds', [])
    required = request.get('requiredModels', ['turns', 'wiring'])
    # A run that saved no session, such as a refused /fork, is judged by its
    # wiring alone.
    if request.get('version') != 1 or (not ids and required != ['wiring']) or len(ids) != len(set(ids)) or not all(isinstance(s, str) and VALID_ID.fullmatch(s) for s in ids):
        raise ValueError('version 1 and unique safe sessionIds required, nonempty unless only wiring is')
    if not required or not set(required) <= {'turns', 'children', 'fork', 'wiring'} or len(required) != len(set(required)):
        raise ValueError('requiredModels must be a nonempty unique supported model set')
    root = Path(request['sessionsRoot'])
    snapshot = report / 'input/sessions'
    snapshot.mkdir(parents=True)
    checks, observed = [], {}
    for sid in ids:
        try:
            if not stat.S_ISDIR((root / sid).lstat().st_mode):
                raise Inconclusive('expected session folder is missing or a symlink')
            data = read_regular(root / sid / 'log.jsonl')
            destination = snapshot / sid
            destination.mkdir()
            (destination / 'log.jsonl').write_bytes(data)
            lines = checked_lines(data)
            if lines[0].get('id') != sid:
                raise Inconclusive('session id does not match its expected folder')
            for line in lines:
                if line.get('kind') in saved.CHILD_KINDS:
                    child = line.get('child')
                    if not isinstance(child, str) or not VALID_ID.fullmatch(child):
                        raise Inconclusive('unsafe child identifier')
                    if (root / child / 'log.jsonl').exists() and child not in ids:
                        raise Inconclusive('existing child log omitted from explicit session set')
            observed[sid] = lines
        except (Inconclusive, OSError) as error:
            checks.append({'kind': 'input', 'sessionId': sid, 'verdict': 'INCONCLUSIVE', 'detail': str(error)})
    java, version = find_java()
    jar = Path(os.environ.get('TLA2TOOLS_JAR', str(Path.home() / '.local/share/tla/tla2tools.jar'))).resolve()
    if not jar.is_file():
        raise RuntimeError(f'missing {jar} (set TLA2TOOLS_JAR)')
    executor = RetainedTLC(report, java, jar)
    # The archives expose generator functions with a module-local executor.
    # Bind that callback only in this new, single-threaded CLI process.
    saved.run_tlc = executor.run
    wiring.run_tlc = executor.run
    children_checked = forks_checked = 0
    for sid, lines in observed.items():
        try:
            if 'turns' in required:
                target = saved.turn_target(lines)
                executor.expected = len(target)
                saved.check_turns(target)
                checks.append({'kind': 'turns', 'sessionId': sid, **executor.last})
            if 'children' in required:
                target, final = saved.child_target(lines, str(snapshot))
                if target:
                    executor.expected = len(target)
                    saved.check_children(target, final)
                    children_checked += 1
                    checks.append({'kind': 'children', 'sessionId': sid, **executor.last})
            if 'fork' in required and lines[0].get('forked_from'):
                copied, source = saved.fork_target(saved.read_lines(snapshot / sid / 'log.jsonl', raw=True), str(snapshot))
                executor.expected = len(copied)
                saved.check_fork(copied, source)
                forks_checked += 1
                checks.append({'kind': 'fork', 'sessionId': sid, **executor.last})
        except (saved.Unreadable, KeyError, TypeError, ValueError) as error:
            checks.append({'kind': 'projection', 'sessionId': sid, 'verdict': 'INCONCLUSIVE', 'detail': str(error)})
    if 'children' in required and children_checked == 0:
        checks.append({'kind': 'children', 'verdict': 'INCONCLUSIVE', 'detail': 'required child work evidence is empty'})
    if 'fork' in required and forks_checked == 0:
        checks.append({'kind': 'fork', 'verdict': 'INCONCLUSIVE', 'detail': 'required fork evidence is empty'})
    if 'wiring' in required:
        try:
            data = read_regular(Path(request['wiringTrace']))
            (report / 'input/wiring.log').write_bytes(data)
            steps, sessions = checked_wiring(data.decode('utf8'), request.get('processes', []))
            executor.expected = len(steps)
            wiring.check(steps, sessions)
            checks.append({'kind': 'wiring', **executor.last})
        except (Inconclusive, UnicodeDecodeError) as error:
            checks.append({'kind': 'wiring', 'verdict': 'INCONCLUSIVE', 'detail': str(error)})
    return {'version': 1, 'verdict': aggregate(checks), 'checks': checks, 'java': java, 'javaVersion': version,
            'jarHash': sha256(jar), 'requestHash': sha256(report / 'request.json'),
            'checkerHash': sha256(Path(__file__)),
            'projectionHashes': {name: sha256(ARCHIVE / name) for name in ('check_saved_logs.py', 'check_wiring_traces.py')},
            'scope': 'Observed TurnLifecycle/Subagents/ForkLog/Wiring projections only; not all per-PR model refinement.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = args.report.resolve()
    report.mkdir(parents=True, exist_ok=False)
    checks = []
    try:
        raw = read_regular(args.request)
        (report / 'request.json').write_bytes(raw)
        result = verify(json.loads(raw), report)
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, Inconclusive) as error:
        result = {'version': 1, 'verdict': 'TOOL_ERROR', 'checks': checks, 'detail': str(error)}
    result['report'] = str(report)
    (report / 'verdict.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return {'ACCEPTED': 0, 'REJECTED': 1, 'INCONCLUSIVE': 2, 'TOOL_ERROR': 3}[result['verdict']]


if __name__ == '__main__':
    sys.exit(main())
