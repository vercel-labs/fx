import { strict as assert } from "node:assert";
import { deflateSync, inflateSync } from "node:zlib";

// Equivalent pixels with different transport sizes, both below image admission limits.
export function equivalentPngEncodings(): Buffer[] {
  const width = 1024, height = 800, stride = width * 4 + 1;
  const pixels = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    pixels.set([0, 128, 128, 255], y * stride + 1 + x * 4);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 6;
  return [9, 0].map(level => {
    const compressed = deflateSync(pixels, { level });
    assert.deepEqual(inflateSync(compressed), pixels);
    const png = Buffer.concat([
      Buffer.from("89504e470d0a1a0a", "hex"),
      pngChunk("IHDR", header), pngChunk("IDAT", compressed), pngChunk("IEND", Buffer.alloc(0)),
    ]);
    assert.ok(Math.ceil(png.length / 3) * 4 < 5 * 1024 * 1024);
    return png;
  });
}

function pngChunk(type: string, data: Buffer): Buffer {
  const tag = Buffer.from(type), length = Buffer.alloc(4), checksum = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  let crc = 0xffffffff;
  for (const bytes of [tag, data]) for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([length, tag, data, checksum]);
}
