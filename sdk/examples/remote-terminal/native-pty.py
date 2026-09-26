import base64
import errno
import fcntl
import json
import os
import pty
import selectors
import signal
import socket
import struct
import sys
import termios


def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()


initial = b""
while not initial.endswith(b"\n"):
    byte = os.read(sys.stdin.fileno(), 1)
    if not byte:
        sys.exit(0)
    initial += byte
    if len(initial) > 1048576:
        sys.exit(1)
config = json.loads(initial)
interaction, child_interaction = socket.socketpair()
os.set_inheritable(child_interaction.fileno(), True)
pid, master = pty.fork()
if pid == 0:
    interaction.close()
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
    os.environ["FX_INTERACTION_FD"] = str(child_interaction.fileno())
    os.chdir(config["cwd"])
    os.environ.update(config.get("env", {}))
    os.environ["TERM"] = "xterm-256color"
    os.execvpe(config["command"], [config["command"], *config.get("args", [])], os.environ)

child_interaction.close()
interaction.setblocking(False)
os.set_blocking(master, False)
selector = selectors.DefaultSelector()
selector.register(master, selectors.EVENT_READ)
selector.register(interaction, selectors.EVENT_READ)
selector.register(sys.stdin.fileno(), selectors.EVENT_READ)
buffer = b""
pending = b""
interaction_buffer = b""
interaction_pending = b""
rejected_writer = None
emit({"type": "started", "pid": pid})
try:
    running = True
    while running:
        for key, events in selector.select():
            if key.fd == master:
                if events & selectors.EVENT_WRITE:
                    try:
                        pending = pending[os.write(master, pending):]
                    except BlockingIOError:
                        pass
                    selector.modify(master, selectors.EVENT_READ | (selectors.EVENT_WRITE if pending else 0))
                if not events & selectors.EVENT_READ:
                    continue
                try:
                    data = os.read(master, 16384)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b""
                if not data:
                    running = False
                    break
                emit({"type": "output", "data": base64.b64encode(data).decode("ascii")})
            elif key.fileobj is interaction:
                if events & selectors.EVENT_WRITE:
                    try:
                        interaction_pending = interaction_pending[interaction.send(interaction_pending):]
                    except BlockingIOError:
                        pass
                    selector.modify(interaction, selectors.EVENT_READ | (selectors.EVENT_WRITE if interaction_pending else 0))
                if not events & selectors.EVENT_READ:
                    continue
                data = interaction.recv(65536)
                if not data:
                    selector.unregister(interaction)
                    continue
                interaction_buffer += data
                while b"\n" in interaction_buffer:
                    line, interaction_buffer = interaction_buffer.split(b"\n", 1)
                    if len(line) > 1048576:
                        raise ValueError("Interaction snapshot exceeds limit")
                    emit({"type": "interaction", "snapshot": json.loads(line)})
                if len(interaction_buffer) > 1048576:
                    raise ValueError("Interaction snapshot exceeds limit")
            else:
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    running = False
                    break
                buffer += data
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    message = json.loads(line)
                    writer = message.get("writerId")
                    if writer is not None and writer == rejected_writer:
                        continue
                    if message["type"] == "input":
                        incoming = (base64.b64decode(message["data"], validate=True) if message.get("encoding") == "base64" else message["data"].encode("utf-8"))
                        if len(pending) + len(incoming) > 65536:
                            rejected_writer = writer
                            emit({"type": "input_rejected", "writerId": writer, "message": "PTY input queue is full"})
                            continue
                        pending += incoming
                        selector.modify(master, selectors.EVENT_READ | selectors.EVENT_WRITE)
                    elif message["type"] == "resize":
                        size = struct.pack("HHHH", message["rows"], message["cols"], 0, 0)
                        fcntl.ioctl(master, termios.TIOCSWINSZ, size)
                    elif message["type"] == "interrupt":
                        termios.tcflush(master, termios.TCIFLUSH)
                        pending = b"\x03"
                        selector.modify(master, selectors.EVENT_READ | selectors.EVENT_WRITE)
                    elif message["type"] == "interaction":
                        incoming = json.dumps(message["action"]).encode("utf-8") + b"\n"
                        if len(interaction_pending) + len(incoming) > 1048576:
                            rejected_writer = writer
                            emit({"type": "input_rejected", "writerId": writer, "message": "Interaction input queue is full"})
                            continue
                        interaction_pending += incoming
                        selector.modify(interaction, selectors.EVENT_READ | selectors.EVENT_WRITE)
                    elif message["type"] == "close":
                        running = False
                        break
finally:
    selector.close()
    try:
        foreground = os.tcgetpgrp(master)
        if foreground > 0 and foreground != pid:
            os.killpg(foreground, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        pass
    os.close(master)
    interaction.close()
    finished, status = os.waitpid(pid, os.WNOHANG)
    if not finished:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _, status = os.waitpid(pid, 0)
    code = os.waitstatus_to_exitcode(status)
    emit({"type": "exit", "code": min(255, 128 - code) if code < 0 else code})
