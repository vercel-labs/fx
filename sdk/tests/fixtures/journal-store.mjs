import { closeSync, fsyncSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export function createJournalStore(initialJournal = []) {
  const directory = mkdtempSync(join(tmpdir(), "libfx-test-journal-"));
  const path = join(directory, "entries.jsonl");
  let lastSeq = initialJournal.at(-1)?.seq ?? 0;
  if (initialJournal.length) {
    const file = openSync(path, "wx", 0o600);
    try {
      writeFileSync(file, initialJournal.map(entry => JSON.stringify({ ...entry, bytes: Buffer.from(entry.bytes).toString("base64") })).join("\n") + "\n");
      fsyncSync(file);
    } finally { closeSync(file); }
  }
  return {
    options(journal = initialJournal) {
      return { journal, onEntry(entry) {
        if (entry.seq !== lastSeq + 1) throw new Error("JournalConflict");
        const file = openSync(path, "a", 0o600);
        try {
          writeFileSync(file, JSON.stringify({ ...entry, bytes: Buffer.from(entry.bytes).toString("base64") }) + "\n");
          fsyncSync(file);
        } finally { closeSync(file); }
        lastSeq = entry.seq;
      } };
    },
    read() {
      if (!lastSeq) return [];
      return readFileSync(path, "utf8").trim().split("\n").map((line) => {
        const entry = JSON.parse(line);
        return { ...entry, bytes: Uint8Array.from(Buffer.from(entry.bytes, "base64")) };
      });
    },
    close() { rmSync(directory, { recursive: true, force: true }); },
  };
}
