// What a libfx simulation checks, from the outside: what each model request
// carries, and what the store holds. Each check returns the rules a run broke,
// as sentences, so a failure says which rule and where.

// Every model request libfx sends: what fits is decided against this, the
// provider limit libfx assumes until a provider refuses a request as too large.
export const defaultRequestBytes = 30 * 1024 * 1024;
// The native addon's fetch bridge carries at most 8 MiB, less room for a
// request's method, URL and headers.
export const nativeRequestBytes = 8 * 1024 * 1024 - 144 * 1024;
const defaultWindow = { images: 4096, bytes: 512 * 1024 * 1024 };
// libfx decides how many images to leave out of a request before it writes
// their notes, so it can't know their exact size. The check allows it to plan
// up to this many bytes for each note; past that, leaving an image out wastes
// room the image would have fit in.
const planningAllowance = 512;

/** The bytes a PNG with base64 `data` takes as a file part of a request. */
function filePartBytes(data, inParts) {
  const part = Buffer.byteLength(JSON.stringify({ type: "file", mediaType: "image/png", data: { type: "data", data } })) + 1;
  // A message of plain text becomes a list of parts once it holds an image.
  return inParts ? part : part + Buffer.byteLength('[{"type":"text","text":}]');
}

// What adding the user message that carries a tool result's images takes, at
// most: libfx leaves it out when it sends none of the result's images.
const toolFollowupBytes = 256;

/** The bytes a note's text takes in a request's JSON. */
const noteBytes = (note) => (note === undefined ? 0 : Buffer.byteLength(JSON.stringify(note)) - 2);

/**
 * What a run knows while it checks requests: the images each prompt carried
 * (`prompts`, marker to pool indices), the image window, which images a
 * request has shown dropped from the session, which no later one may send,
 * the form each steer came in (`steerForms`, id to "live" or "plain"),
 * which no later request may change, and the images each turn's tool call
 * returned (`tools`, marker to pool indices).
 */
export function requestContext({ pool, prompts, window, steerForms, tools }) {
  return { pool, prompts, window: window ?? defaultWindow, dropped: new Set(), steerForms: new Map(steerForms ?? []), tools: tools ?? new Map() };
}

/**
 * The window rules a request broke when its open turn starts at user message
 * `start`: no image of the open turn's prompt left the session, the history
 * keeps every image that fits the window, and no more.
 */
function windowRulesFor(entries, start, window, pool) {
  const broken = [];
  for (const entry of entries) {
    if (entry.status === "window" && entry.position === start && entry.newest) broken.push(`${entry.key} was dropped from the turn that is running`);
    // A tool result after the open turn's start is the running turn's.
    if (entry.status === "window" && entry.tool && entry.position > start) broken.push(`${entry.key}, a tool image of the turn that is running, was dropped`);
  }
  const history = entries.filter((entry) => entry.position < start);
  const keptHistory = history.filter((entry) => entry.status !== "window");
  const keptBytes = keptHistory.reduce((sum, entry) => sum + pool.images[entry.index].byteLength, 0);
  const newestDropped = history.filter((entry) => entry.status === "window").at(-1);
  if (newestDropped && keptHistory.length < window.images && keptBytes + pool.images[newestDropped.index].byteLength <= window.bytes) {
    broken.push(`the session dropped ${newestDropped.key}, which fit its window`);
  }
  if (keptHistory.length > window.images || keptBytes > window.bytes) {
    broken.push(`the session kept ${keptHistory.length} images (${keptBytes} bytes), past its window`);
  }
  return broken;
}

/**
 * The rules request `observed` broke. `cap` is the size libfx had to fit the
 * request within: the transport's limit or a smaller one a provider taught it.
 * `fitCap`, at most `cap`, is the smallest limit libfx may have learned: one
 * from a refusal it handled before a cancel stopped the retry. An image left
 * out only breaks a rule when it fits that one too.
 */
export function checkRequest(observed, context, cap, fitCap = cap) {
  const broken = [];
  const { pool, prompts, window, dropped, steerForms, tools } = context;
  // A steer keeps the form it first came in, in every later request and in a
  // reopened session's: a live update of the turn it joined, or the plain
  // text of a turn of its own.
  const formName = (form) => (form === "live" ? "a live update" : "plain text");
  for (const user of observed.users) {
    const form = user.text.startsWith("<user_steering>") ? "live" : "plain";
    for (const [id] of user.text.matchAll(/steer-\d+-\d+/g)) {
      const first = steerForms.get(id);
      if (first === undefined) steerForms.set(id, form);
      else if (first !== form) broken.push(`steer ${id} came as ${formName(first)}, and now comes as ${formName(form)}`);
    }
  }
  const entries = [];
  observed.users.forEach((user, position) => {
    if (user.tool) {
      // A tool result's images, oldest first: those dropped from the session,
      // then those left out for size, then the ones it sends, as they were.
      const { key, windowNoted, sizeNoted, sent, results } = user.tool;
      if (results > 1) broken.push(`a tool message holds ${results} results, and a simulated turn makes one call at a time`);
      const images = (key && tools.get(key)) || [];
      if (windowNoted + sizeNoted + sent.length !== images.length) {
        broken.push(`the tool result of ${key ?? "an unknown call"} accounts for ${windowNoted + sizeNoted + sent.length} images (${windowNoted} dropped, ${sizeNoted} left out, ${sent.length} sent), and the tool returned ${images.length}`);
        return;
      }
      images.forEach((index, at) => {
        const status = at < windowNoted ? "window" : at < windowNoted + sizeNoted ? "size" : "sent";
        if (status === "sent" && sent[at - windowNoted - sizeNoted] !== pool.base64[index]) broken.push(`the tool result of ${key} carries other bytes for its image ${at + 1}`);
        entries.push({
          key: `${key}:tool:${at}`,
          index,
          status,
          position,
          newest: false,
          tool: true,
          // Sending it in place of its note may also add the message that
          // carries the result's images.
          ...(status === "size" ? { noteBytes: sent.length > 0 ? 0 : -toolFollowupBytes, inParts: true } : {}),
        });
      });
      return;
    }
    const sent = [...user.sent];
    const named = new Set(user.segments.flatMap((segment) => segment.ids));
    for (const id of [...user.windowNoted, ...user.sizeNoted]) {
      if (!named.has(id)) broken.push(`a user message notes image #${id}, which it does not hold`);
    }
    user.segments.forEach((segment, at) => {
      const images = segment.marker === null ? undefined : prompts.get(segment.marker);
      // The newest prompt of its message.
      const newest = at === user.segments.findLastIndex((segment) => segment.marker !== null);
      if (images === undefined) {
        if (segment.ids.length > 0) broken.push(`${segment.ids.length} images follow text that is no prompt's`);
        return;
      }
      if (segment.ids.length !== images.length) {
        broken.push(`${segment.marker} names ${segment.ids.length} images, but its prompt had ${images.length}`);
        return;
      }
      segment.ids.forEach((id, index) => {
        const window = user.windowNoted.has(id);
        const size = user.sizeNoted.has(id);
        if (window && size) broken.push(`${segment.marker} notes image #${id} both as dropped and as withheld`);
        const status = window ? "window" : size ? "size" : "sent";
        if (status === "sent") {
          const data = sent.shift();
          if (data === undefined) broken.push(`${segment.marker} is missing its image ${index + 1}`);
          else if (data !== pool.base64[images[index]]) broken.push(`${segment.marker} carries other bytes for its image ${index + 1}`);
        }
        entries.push({
          key: `${segment.marker}:${index}`,
          index: images[index],
          status,
          position,
          newest,
          ...(status === "size" ? { noteBytes: noteBytes(user.sizeNotes.get(id)), inParts: user.inParts } : {}),
        });
      });
    });
    if (sent.length > 0) broken.push(`a user message carries ${sent.length} images no placeholder names`);
  });

  // Dropped from the session stays dropped, oldest first.
  for (const entry of entries) {
    if (entry.status !== "window" && dropped.has(entry.key)) broken.push(`${entry.key} came back after the session dropped it`);
  }
  const firstKept = entries.findIndex((entry) => entry.status !== "window");
  if (firstKept >= 0 && entries.slice(firstKept).some((entry) => entry.status === "window")) {
    broken.push("the session dropped a newer image and kept an older one");
  }
  for (const entry of entries) if (entry.status === "window") dropped.add(entry.key);
  // The window counts the history, the turns before the open one; the open
  // turn's images join it once the turn ends. The open turn starts at its
  // prompt, or at a steer that runs as a turn of its own. A steer that joined
  // a turn is a live update in it, and starts nothing.
  const start = observed.users.findLastIndex((user) => user.startsTurn);
  broken.push(...windowRulesFor(entries, start >= 0 ? start : observed.users.length, window, pool));

  // Left out for size, oldest first, only when they don't fit.
  const inSession = entries.filter((entry) => entry.status !== "window");
  const firstSent = inSession.findIndex((entry) => entry.status === "sent");
  if (firstSent >= 0 && inSession.slice(firstSent).some((entry) => entry.status === "size")) {
    broken.push("the request left out a newer image and sent an older one");
  }
  const sent = inSession.filter((entry) => entry.status === "sent").length;
  if (sent > 100) broken.push(`the request carries ${sent} images, more than 100`);
  if (observed.bytes > cap && sent > 0) broken.push(`the request is ${observed.bytes} bytes, past ${cap}, with images still in it`);
  // Left out only when it must be: sending the newest image left out, in
  // place of its note, would break the size cap or the image cap. What that
  // request would weigh is measured from this one: the note's bytes go, and
  // the image's file part comes.
  const withheld = inSession.filter((entry) => entry.status === "size");
  const newestWithheld = withheld.at(-1);
  if (newestWithheld && sent < 100) {
    const withIt = observed.bytes - newestWithheld.noteBytes + filePartBytes(pool.base64[newestWithheld.index], newestWithheld.inParts);
    if (withIt + planningAllowance * withheld.length <= fitCap) {
      broken.push(`the request left out ${newestWithheld.key}, which fit (${withIt} bytes with it, against ${fitCap})`);
    }
  }
  return broken;
}

const decoder = new TextDecoder();

/**
 * The image names a store's saved data gives for images the session holds.
 * One it dropped keeps only its name, which needs no bytes: an image the
 * session held inline takes its name when it leaves the window.
 */
function savedNames(store) {
  const found = new Set();
  const visit = (value) => {
    if (Array.isArray(value)) return value.forEach(visit);
    if (!value || typeof value !== "object") return;
    if (typeof value.inline_ref === "string" && value.dropped !== true) found.add(value.inline_ref);
    for (const item of Object.values(value)) visit(item);
  };
  for (const record of store.records) visit(JSON.parse(decoder.decode(record.data)));
  if (store.checkpoint) {
    const text = Buffer.from(store.checkpoint.data).toString("latin1");
    for (const match of text.matchAll(/"inline_ref":"([0-9a-f]{64})"(?!,"dropped":true)/g)) found.add(match[1]);
  }
  return found;
}

/**
 * The rules a store's saved data broke: it names images, never holds them,
 * except the tool images in `inline` (pool indices), which the store refused
 * after their tool had run, so the session keeps them in the result.
 */
export function checkSaved(store, pool, inline = new Set()) {
  const broken = [];
  const held = (data) => pool.images.findIndex((_, index) => !inline.has(index) && pool.heldIn(data, index));
  for (const record of store.records) {
    const index = held(record.data);
    if (index >= 0) broken.push(`record ${record.cursor} holds image ${index}'s bytes`);
  }
  if (store.checkpoint) {
    const index = held(store.checkpoint.data);
    if (index >= 0) broken.push(`the checkpoint holds image ${index}'s bytes`);
  }
  for (const name of savedNames(store)) {
    if (!store.images.has(name)) broken.push(`saved data names image ${name.slice(0, 12)}, which the store does not hold`);
  }
  return broken;
}
