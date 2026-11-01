// Connects an xterm.js Terminal to an fx terminal, native or WebAssembly.
const decoder = new TextDecoder();

export function encodeXtermKeyEvent(event) {
  if (event.type !== "keydown" || event.altKey || event.ctrlKey) return null;
  if (event.key === "Enter" && event.shiftKey && !event.metaKey) return "\x1b[13;2u";
  if (event.metaKey) {
    const modifiers = 8 | (event.shiftKey ? 1 : 0);
    if (event.key === "Backspace") return `\x1b[127;${modifiers + 1}u`;
    const arrow = { ArrowUp: "A", ArrowDown: "B", ArrowRight: "C", ArrowLeft: "D" }[event.key];
    if (arrow) return `\x1b[1;${modifiers + 1}${arrow}`;
    const shortcut = { a: 97, c: 99, x: 120, z: 122 }[event.key.toLowerCase()];
    if (shortcut) return `\x1b[${shortcut};${modifiers + 1}u`;
  }
  return null;
}

function xtermPointerCell(term, event) {
  const root = term.element;
  const screen = root?.querySelector?.(".xterm-screen") || root;
  const rect = screen?.getBoundingClientRect?.();
  if (!rect || rect.width <= 0 || rect.height <= 0 || term.cols <= 0 || term.rows <= 0) return null;
  if (event.clientX < rect.left || event.clientX >= rect.right ||
    event.clientY < rect.top || event.clientY >= rect.bottom) return null;
  return {
    column: Math.min(term.cols, Math.floor((event.clientX - rect.left) * term.cols / rect.width) + 1),
    row: Math.min(term.rows, Math.floor((event.clientY - rect.top) * term.rows / rect.height) + 1),
  };
}

function installXtermClickHandler(term, callback) {
  const element = term.element;
  if (typeof element?.addEventListener !== "function") return () => {};
  let pointerDown = null;
  const down = (event) => {
    if (event.button !== 0) return;
    pointerDown = { id: event.pointerId, x: event.clientX, y: event.clientY };
  };
  const up = (event) => {
    const start = pointerDown;
    pointerDown = null;
    if (!start || event.button !== 0 || event.pointerId !== start.id ||
      event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    if (dx * dx + dy * dy > 16) return;
    if (term.modes?.mouseTrackingMode && term.modes.mouseTrackingMode !== "none") return;
    const cell = xtermPointerCell(term, event);
    if (!cell) return;
    callback(`\x1b[<0;${cell.column};${cell.row}M\x1b[<0;${cell.column};${cell.row}m`);
  };
  const cancel = () => { pointerDown = null; };
  element.addEventListener("pointerdown", down);
  element.addEventListener("pointerup", up);
  element.addEventListener("pointercancel", cancel);
  return () => {
    element.removeEventListener("pointerdown", down);
    element.removeEventListener("pointerup", up);
    element.removeEventListener("pointercancel", cancel);
  };
}

function installXtermShortcutHandler(term, callback) {
  const element = term.element;
  if (typeof element?.addEventListener !== "function") return () => {};
  const keydown = (event) => {
    if (xtermSelectionOwnsShortcut(term, event)) return;
    const data = encodeXtermKeyEvent(event);
    if (data === null) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    callback(data);
  };
  element.addEventListener("keydown", keydown, true);
  return () => element.removeEventListener("keydown", keydown, true);
}

function xtermSelectionOwnsShortcut(term, event) {
  return event.type === "keydown" && event.metaKey &&
    (event.key.toLowerCase() === "c" || event.key.toLowerCase() === "x") &&
    term.hasSelection?.();
}

export function xtermAdapter(term) {
  let keyDataHandler = null;
  if (typeof term.attachCustomKeyEventHandler === "function") {
    term.attachCustomKeyEventHandler((event) => {
      if (xtermSelectionOwnsShortcut(term, event)) return true;
      const data = encodeXtermKeyEvent(event);
      if (data === null || keyDataHandler === null) return true;
      keyDataHandler(data);
      return false;
    });
  }
  return {
    write(bytes) { term.write(typeof bytes === "string" ? bytes : decoder.decode(bytes)); },
    onData(callback) { const disposable = term.onData(callback); return () => disposable.dispose(); },
    onKeyData(callback) {
      keyDataHandler = callback;
      const removeShortcutHandler = installXtermShortcutHandler(term, callback);
      const removeClickHandler = installXtermClickHandler(term, callback);
      return () => {
        removeShortcutHandler();
        removeClickHandler();
        if (keyDataHandler === callback) keyDataHandler = null;
      };
    },
    get cols() { return term.cols; },
    get rows() { return term.rows; },
    onResize(callback) { const disposable = term.onResize(callback); return () => disposable.dispose(); },
  };
}
