// A set of short strings in shared memory, so the worker threads of one
// driver see one set, as the agents of one process see one Set. Each slot
// holds a length byte and up to 63 bytes of UTF-8; a spin lock guards every
// read and write, which take microseconds.
const slotBytes = 64;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** The memory for one set, to pass to every thread through `workerData`. */
export function sharedSetBuffer(slots = 1024) {
  return new SharedArrayBuffer(8 + slots * slotBytes);
}

/** A Set-like view of `buffer`: has, add, delete, claim, clear, size, iteration. */
export function sharedSet(buffer) {
  const lock = new Int32Array(buffer, 0, 1);
  const bytes = new Uint8Array(buffer, 8);
  const slots = bytes.length / slotBytes;
  const locked = (fn) => {
    while (Atomics.compareExchange(lock, 0, 0, 1) !== 0);
    try {
      return fn();
    } finally {
      Atomics.store(lock, 0, 0);
    }
  };
  // TextDecoder takes no shared memory, so a slot is copied out first.
  const read = (slot) => decoder.decode(bytes.slice(slot * slotBytes + 1, slot * slotBytes + 1 + bytes[slot * slotBytes]));
  const find = (value) => {
    for (let slot = 0; slot < slots; slot += 1) if (bytes[slot * slotBytes] !== 0 && read(slot) === value) return slot;
    return -1;
  };
  const insert = (value) => {
    const encoded = encoder.encode(value);
    if (encoded.length === 0 || encoded.length >= slotBytes) throw new Error(`a shared set holds strings of 1 to ${slotBytes - 1} bytes, not ${JSON.stringify(value)}`);
    if (find(value) >= 0) return false;
    for (let slot = 0; slot < slots; slot += 1) {
      if (bytes[slot * slotBytes] !== 0) continue;
      bytes.set(encoded, slot * slotBytes + 1);
      bytes[slot * slotBytes] = encoded.length;
      return true;
    }
    throw new Error("the shared set is full");
  };
  const values = () => locked(() => {
    const found = [];
    for (let slot = 0; slot < slots; slot += 1) if (bytes[slot * slotBytes] !== 0) found.push(read(slot));
    return found;
  });
  const set = {
    has: (value) => locked(() => find(String(value)) >= 0),
    add(value) {
      locked(() => insert(String(value)));
      return set;
    },
    // Adds `value` and says whether it was new, in one step, so two threads
    // never both take it.
    claim: (value) => locked(() => insert(String(value))),
    delete: (value) => locked(() => {
      const slot = find(String(value));
      if (slot < 0) return false;
      bytes[slot * slotBytes] = 0;
      return true;
    }),
    clear: () => locked(() => {
      for (let slot = 0; slot < slots; slot += 1) bytes[slot * slotBytes] = 0;
    }),
    get size() {
      return values().length;
    },
    values: () => values()[Symbol.iterator](),
    [Symbol.iterator]: () => values()[Symbol.iterator](),
  };
  return set;
}
