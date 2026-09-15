#!/usr/bin/env python3
"""Exercise the freshly copied fx through a real guest pseudo-terminal."""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import termios
import time

if not subprocess.check_output(['sysctl', '-n', 'hw.model'], text=True).startswith('VirtualMac'):
    raise SystemExit('refusing physical host')
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 110, 0, 0))
env = dict(os.environ, TERM='xterm-256color', AI_GATEWAY_API_KEY='', VERCEL_OIDC_TOKEN='')
def attach_terminal():
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
p = subprocess.Popen(['./zig-out/bin/fx'], stdin=slave, stdout=slave, stderr=subprocess.PIPE, env=env, preexec_fn=attach_terminal)
os.close(slave)
output = bytearray()
def drain(seconds):
    end = time.monotonic()+seconds
    while time.monotonic()<end:
        if select.select([master], [], [], min(0.1, max(0,end-time.monotonic())))[0]:
            try:
                b=os.read(master,65536)
                if not b: break
                output.extend(b)
            except OSError as e:
                if e.errno!=errno.EIO: raise
                break
def send(data):
    try:
        os.write(master,data)
    except OSError as e:
        if e.errno!=errno.EIO: raise
try:
    drain(3)
    send(b'\x1b')
    drain(1)
    send(b'/help\r')
    drain(3)
    send(b'\x1b')
    drain(1)
    send(b'/exit\r')
    drain(2)
    if p.poll() is None:
        send(b'\x03')
        drain(1)
    if p.poll() is None:
        send(b'\x03')
        drain(1)
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill(); p.wait()
    err=p.stderr.read().decode(errors='replace')
    Path('tui-output.ansi').write_bytes(output)
    result=dict(returncode=p.returncode, stdout_bytes=len(output),stderr=err,
                transcript=output.decode(errors='replace'))
    print(json.dumps(result,indent=2))
    if p.returncode != 0 or err or b'start a fresh session' not in output:
        raise SystemExit(1)
finally:
    if p.poll() is None: p.kill(); p.wait()
    os.close(master)
