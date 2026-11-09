import { Buffer } from "node:buffer";
import { readFileSync } from "node:fs";

export type TapeFrame = {
  index: number;
  deltaMs: number;
  kind: number;
  payload: Buffer;
};

/// Every frame of the tape at `path`. A final frame cut short, as a killed
/// process can leave it, throws unless `ignoreTruncatedTail` is set; then it
/// is left out, as `fx replay` leaves it out.
export function readTapeFrames(path: string, options: { ignoreTruncatedTail?: boolean } = {}): TapeFrame[] {
  const bytes = readFileSync(path);
  const magic = Buffer.from("FXTP\x01", "binary");
  if (!bytes.subarray(0, magic.length).equals(magic)) {
    throw new Error("invalid tape magic");
  }

  let offset = magic.length + 2 + 2 + 8;
  if (offset >= bytes.length) throw new Error("truncated tape header");
  const versionLen = bytes.readUInt8(offset);
  offset += 1 + versionLen;
  if (offset > bytes.length) throw new Error("truncated tape version");

  const frames: TapeFrame[] = [];
  let index = 0;
  while (offset < bytes.length) {
    if (offset + 9 > bytes.length) {
      if (options.ignoreTruncatedTail) break;
      throw new Error(`truncated tape frame header at ${offset}`);
    }
    const deltaMs = bytes.readInt32LE(offset);
    const kind = bytes.readUInt8(offset + 4);
    const len = bytes.readUInt32LE(offset + 5);
    const start = offset + 9;
    const end = start + len;
    if (end > bytes.length) {
      if (options.ignoreTruncatedTail) break;
      throw new Error(`truncated tape frame payload at ${offset}`);
    }
    frames.push({ index: ++index, deltaMs, kind, payload: bytes.subarray(start, end) });
    offset = end;
  }
  return frames;
}

export function stdoutFrames(path: string): TapeFrame[] {
  return readTapeFrames(path).filter((frame) => frame.kind === 1);
}
