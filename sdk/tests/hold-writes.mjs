// A durability whose session-log writes a test holds until it lets them go,
// so it decides when a worker's claim lands. Works on memory() and on a
// World durability, local() or vercel(), without hooks in libfx: it wraps the
// memory backend's log, or the World's event writes.
//
//   const [durability, writes] = holdWrites(memory(), (entry) => entry.k === "lease");
//   ...
//   await writes.next();          // a write is held
//   await writes.releaseHeld();   // the held ones go out, and settle
//   writes.release();             // every held and later one goes out
//
// With `landFirst`, a held write lands at once and only its result waits, so
// the log holds it before its worker hears so. With `unreported`, a held
// memory() write the chain refuses resolves as if it landed, as a World that
// takes a write without reporting a competing one would.
const decoder = new TextDecoder();

export function holdWrites(durability, held, { landFirst = false, unreported = false } = {}) {
  const waiting = [];
  const arrivals = [];
  let open = false;
  // Entries the test has let go. libfx sends one again, unchanged, when the
  // World's in-band fence refused it only because a count was still settling;
  // that is still the one write the test released.
  const released = new Set();
  // Holds `entry` when the test wants it held; returns what to call once the
  // write it held has settled.
  const pause = async (entry) => {
    if (open || !held(entry)) return () => {};
    const key = JSON.stringify(entry);
    if (released.has(key)) return () => {};
    let done;
    const finished = new Promise((resolve) => { done = resolve; });
    await new Promise((go) => {
      waiting.push({ entry, go: () => { released.add(key); go(); }, finished });
      arrivals.shift()?.();
    });
    return done;
  };
  const after = async (entry, write) => {
    if (landFirst) {
      const landed = await write();
      (await pause(entry))();
      return landed;
    }
    const done = await pause(entry);
    try {
      return await write();
    } catch (error) {
      if (unreported && error?.code === "FX_FENCED" && held(entry)) return entry.a;
      throw error;
    } finally {
      done();
    }
  };
  const writes = {
    // The entries held now.
    get held() { return waiting.map((item) => item.entry); },
    // Resolves once a write is held.
    next() {
      if (waiting.length > 0) return Promise.resolve();
      return new Promise((arrived) => arrivals.push(arrived));
    },
    // Lets the writes held now go, in order, and holds later ones again.
    // Resolves once they have settled.
    releaseHeld() {
      const items = waiting.splice(0);
      for (const item of items) item.go();
      return Promise.all(items.map((item) => item.finished));
    },
    // Lets every held and later write go.
    release() {
      open = true;
      return writes.releaseHeld();
    },
  };
  if (typeof durability.create === "function") {
    const create = durability.create;
    const wrapped = new WeakMap();
    return [{
      ...durability,
      create() {
        const backend = create();
        if (!wrapped.has(backend)) {
          wrapped.set(backend, {
            ...backend,
            async session(id) {
              const log = await backend.session(id);
              return { ...log, append: (entry) => after(entry, () => log.append(entry)) };
            },
          });
        }
        return wrapped.get(backend);
      },
    }, writes];
  }
  const entryOf = (event) => {
    if (event?.eventType !== "step_created" || event.eventData?.stepName !== "fx.log") return null;
    try { return JSON.parse(decoder.decode(event.eventData.input)); } catch { return null; }
  };
  const bound = (target, key) => {
    const value = Reflect.get(target, key);
    return typeof value === "function" ? value.bind(target) : value;
  };
  return [{
    ...durability,
    async world() {
      const world = await durability.world();
      const events = new Proxy(world.events, {
        get(target, key) {
          if (key !== "create") return bound(target, key);
          return async (runId, event, params) => {
            const entry = entryOf(event);
            return entry ? after(entry, () => target.create(runId, event, params)) : target.create(runId, event, params);
          };
        },
      });
      return new Proxy(world, { get: (target, key) => (key === "events" ? events : bound(target, key)) });
    },
  }, writes];
}
