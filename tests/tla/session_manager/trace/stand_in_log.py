#!/usr/bin/env python3
"""A small stand-in for the L1 log, used only to self-test the trace tooling.

It writes a real file with O_APPEND, fsync and simulated crashes, and emits
one trace line per step. The state in each line is read back from the actual
file bytes, the same way the Zig trace hook must do it. Not a design
reference for the Zig code.

usage: stand_in_log.py LOG_PATH TRACE_PATH [keep_torn_tail]
"""
import json
import os
import sys


class Log:
    def __init__(self, path, trace, bug=None):
        self.path, self.trace, self.bug = path, trace, bug
        self.fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        self.durable = self.acked = 0
        self.status, self.pending, self.seq = "open", None, 0

    def disk(self):
        """Abstraction function: file bytes -> (line count, tail done, seqs)."""
        with open(self.path, "rb") as f:
            data = f.read()
        torn = len(data) > 0 and not data.endswith(b"\n")
        complete = data.split(b"\n")[: data.count(b"\n")]
        seqs = []
        for raw in complete:
            try:
                seqs.append(int(json.loads(raw)["seq"]))
            except (ValueError, KeyError, TypeError):
                seqs.append(-1)
        return len(complete) + (1 if torn else 0), not torn, seqs

    def emit(self, event):
        n, done, seqs = self.disk()
        self.trace.write(json.dumps({
            "event": event, "log_len": n, "tail_done": done, "seqs": seqs,
            "durable": self.durable, "acked": self.acked, "status": self.status,
        }) + "\n")

    def begin_write(self):
        """First half of one write(): the newline is not on disk yet."""
        self.seq += 1
        line = json.dumps({"v": 1, "seq": self.seq, "kind": "item"}).encode() + b"\n"
        half = len(line) // 2
        os.write(self.fd, line[:half])
        self.pending = line[half:]
        self.status = "writing"
        self.emit("BeginWrite")

    def finish_write(self):
        os.write(self.fd, self.pending)
        self.pending = None
        self.status = "open"
        self.emit("FinishWrite")

    def fsync(self):
        os.fsync(self.fd)
        self.durable = self.acked = self.disk()[0]
        self.emit("Fsync")

    def process_crash(self):
        os.close(self.fd)
        self.status = "down"
        self.emit("ProcessCrash")

    def power_loss(self, keep, tear):
        """Simulated: keep `keep` complete lines (at least durable), then tear
        the last kept line if it was never fsynced."""
        if self.status != "down":
            os.close(self.fd)
        with open(self.path, "rb") as f:
            data = f.read()
        kept = b"".join(p + b"\n" for p in data.split(b"\n")[:keep])
        if tear and keep > self.durable:
            kept = kept[:-3]
        with open(self.path, "wb") as f:
            f.write(kept)
        self.status = "down"
        self.emit("PowerLoss")

    def recover(self):
        """open(.resume): cut a torn tail, fsync, reopen for append."""
        with open(self.path, "rb") as f:
            data = f.read()
        if data and not data.endswith(b"\n") and self.bug != "keep_torn_tail":
            data = data[: data.rfind(b"\n") + 1]
            with open(self.path, "wb") as f:
                f.write(data)
        self.fd = os.open(self.path, os.O_WRONLY | os.O_APPEND)
        os.fsync(self.fd)
        self.durable = self.disk()[0]
        self.seq = data.count(b"\n")
        self.status = "open"
        self.emit("Recover")


def scenario(path, trace_path, bug=None):
    with open(trace_path, "w") as trace:
        log = Log(path, trace, bug)
        log.begin_write(); log.finish_write()
        log.begin_write(); log.finish_write(); log.fsync()   # 2 acknowledged lines
        log.begin_write(); log.process_crash()                # torn 3rd line
        log.recover()                                         # must cut it
        log.begin_write(); log.finish_write()                 # new 3rd line, not fsynced
        log.power_loss(keep=3, tear=True)                     # machine crash tears it
        log.recover()
        log.begin_write(); log.finish_write(); log.fsync()


if __name__ == "__main__":
    scenario(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
