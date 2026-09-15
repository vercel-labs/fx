import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import struct
import tempfile
import termios
import time


binary = Path(__file__).resolve().parents[2] / 'zig-out' / 'bin' / 'fx'


def exercise():
    with tempfile.TemporaryDirectory(prefix='fx-interaction-') as home:
        parent, child = socket.socketpair()
        child.set_inheritable(True)
        pid, terminal = pty.fork()
        if pid == 0:
            parent.close()
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 100, 0, 0))
            os.chdir(home)
            env = dict(PATH=os.environ.get('PATH', '/usr/bin:/bin'),
                       FX_INTERACTION_FD=str(child.fileno()), TERM='xterm-256color',
                       HOME=home, FX_DISABLE_KEYCHAIN='1', FX_SKIP_ONBOARDING='1',
                       FX_SOUND='0', FX_AUTO_UPGRADE='0',
                       FX_GATEWAY_BASE_URL='http://127.0.0.1:1')
            os.execve(binary, [str(binary)], env)
        child.close()
        parent.setblocking(False)
        pending = bytearray()
        terminal_output = bytearray()

        def send(action):
            parent.sendall((json.dumps(action) + '\n').encode())

        def next_snapshot(predicate):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                while b'\n' in pending:
                    line, _, rest = pending.partition(b'\n')
                    pending[:] = rest
                    snapshot = json.loads(line)
                    if predicate(snapshot):
                        return snapshot
                readable, _, _ = select.select([parent, terminal], [], [], 0.2)
                if terminal in readable:
                    terminal_output.extend(os.read(terminal, 65536))
                if parent in readable:
                    data = parent.recv(1048576)
                    if not data:
                        raise AssertionError('Native interaction socket closed')
                    pending.extend(data)
            raise AssertionError('Native interaction snapshot timed out')

        try:
            initial = next_snapshot(lambda value: value['type'] == 'snapshot')
            assert initial['version'] == 1
            assert any(command['command'] == '/model' for command in initial['commands'])
            assert isinstance(initial['transcript'], list)
            send({'type': 'input', 'text': '/model '})
            picker = next_snapshot(lambda value: value['composer']['text'] == '/model ')
            assert picker['model']['active']
            assert picker['revision'] > initial['revision']
            send({'type': 'model', 'action': 'dismiss', 'revision': picker['revision']})
            dismissed = next_snapshot(lambda value: not value['model']['active'])
            assert dismissed['revision'] > picker['revision']
            send({'type': 'input', 'text': 'native composer'})
            composer = next_snapshot(lambda value: value['composer']['text'] == 'native composer')
            assert composer['composer']['cursor'] == len('native composer')
            send({'type': 'input', 'text': '/help'})
            send({'type': 'submit'})
            next_snapshot(lambda value: value.get('unsupported_screen') == 'help')
            send({'type': 'dismiss'})
            next_snapshot(lambda value: value.get('unsupported_screen') is None)
            assert b'fx: ' not in terminal_output
            print('Native interaction: commands, composer, model picker, revision and dismiss passed')
        finally:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
            parent.close()
            os.close(terminal)


if __name__ == '__main__':
    exercise()
