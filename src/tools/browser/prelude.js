// The browser tool's controller prelude (D195). It runs in a hidden blank
// page, never in the page being driven, so a script keeps running across
// navigations. Each tab method sends one request through the __fxCall
// binding; proto-fx answers with __fxResolve.
(() => {
  "use strict";
  let seq = 0;
  const pending = new Map();
  globalThis.__fxResolve = (id, ok, value) => {
    const entry = pending.get(id);
    if (!entry) return;
    pending.delete(id);
    if (ok) entry.resolve(value);
    else entry.reject(new Error(value));
  };
  const call = (op, args) =>
    new Promise((resolve, reject) => {
      const id = ++seq;
      pending.set(id, { resolve, reject });
      globalThis.__fxCall(JSON.stringify({ id, op, args }));
    });
  const isTarget = (value) => value && typeof value === "object" && value.__fxTarget;
  const target = (value) => {
    if (isTarget(value)) return value.__fxTarget;
    if (typeof value === "string") return { selector: value };
    if (typeof value === "number") return { id: value };
    if (value && typeof value.then === "function") throw new Error("selector is a Promise; add await");
    throw new Error("expected a selector string, an observed id, or a handle from tab.id()/tab.ref()");
  };
  const optionsOf = (value) => (value && typeof value === "object" && !Array.isArray(value) ? value : {});
  const handle = (tabName, spec) => {
    const on = (op, extra) => call(op, Object.assign({ tab: tabName, target: spec }, extra || {}));
    return {
      __fxTarget: spec,
      click: (o) => on("click", optionsOf(o)),
      dblclick: (o) => on("click", Object.assign({ count: 2 }, optionsOf(o))),
      hover: (o) => on("hover", optionsOf(o)),
      focus: () => on("focus"),
      fill: (value, o) => on("fill", Object.assign({ value: String(value) }, optionsOf(o))),
      type: (text, o) => on("type", Object.assign({ text: String(text) }, optionsOf(o))),
      press: (key, o) => on("press", Object.assign({ key }, optionsOf(o))),
      select: (...values) => on("select", { values: values.flat().map(String) }),
      check: () => on("check", { checked: true }),
      uncheck: () => on("check", { checked: false }),
      scrollIntoView: () => on("scrollIntoView"),
      text: () => on("text"),
      value: () => on("value"),
      attribute: (name) => on("attribute", { name: String(name) }),
      boundingBox: () => on("box"),
      screenshot: (o) => on("screenshot", optionsOf(o)),
      evaluate: (fn, ...args) => on("evaluate", { source: String(fn), args, element: true }),
    };
  };
  const scope = (tabName, budget) => {
    const t = (op, extra) => call(op, Object.assign({ tab: tabName }, extra || {}));
    const onTarget = (op, value, extra) => t(op, Object.assign({ target: target(value) }, extra || {}));
    const tab = {
      name: tabName,
      url: () => t("url"),
      title: () => t("title"),
      goto: (url, o) => t("goto", Object.assign({ url: String(url) }, optionsOf(o))),
      back: () => t("history", { delta: -1 }),
      forward: () => t("history", { delta: 1 }),
      reload: (o) => t("reload", optionsOf(o)),
      observe: (o) => t("observe", optionsOf(o)),
      ariaSnapshot: (selector, o) =>
        typeof selector === "string" ? t("aria", Object.assign({ selector }, optionsOf(o))) : t("aria", optionsOf(selector)),
      extract: (format) => t("extract", { format: format || "markdown" }),
      text: (selector) => (selector === undefined ? t("extract", { format: "text" }) : onTarget("text", selector)),
      html: (selector) => (selector === undefined ? t("html") : onTarget("html", selector)),
      screenshot: (o) => {
        if (optionsOf(o).path !== undefined)
          throw new Error("tab.screenshot() takes no path; it saves the image itself and returns the saved path, which you can copy");
        return t("screenshot", optionsOf(o));
      },
      click: (selector, o) => onTarget("click", selector, optionsOf(o)),
      dblclick: (selector, o) => onTarget("click", selector, Object.assign({ count: 2 }, optionsOf(o))),
      hover: (selector, o) => onTarget("hover", selector, optionsOf(o)),
      focus: (selector) => onTarget("focus", selector),
      fill: (selector, value, o) => onTarget("fill", selector, Object.assign({ value: String(value) }, optionsOf(o))),
      type: (selector, text, o) => onTarget("type", selector, Object.assign({ text: String(text) }, optionsOf(o))),
      press: (key, o) => {
        if (typeof o === "string")
          throw new Error(`tab.press() takes (key, options); did you mean tab.press(${JSON.stringify(o)}, { selector: ${JSON.stringify(key)} })?`);
        const opts = optionsOf(o);
        const extra = { key: String(key) };
        if (opts.selector !== undefined) extra.target = target(opts.selector);
        return t("press", extra);
      },
      select: (selector, ...values) => onTarget("select", selector, { values: values.flat().map(String) }),
      check: (selector) => onTarget("check", selector, { checked: true }),
      uncheck: (selector) => onTarget("check", selector, { checked: false }),
      scroll: (deltaX, deltaY) => t("scroll", { deltaX: Number(deltaX) || 0, deltaY: Number(deltaY) || 0 }),
      scrollIntoView: (selector) => onTarget("scrollIntoView", selector),
      waitFor: async (selector, o) => {
        await onTarget("waitFor", selector, optionsOf(o));
        return handle(tabName, target(selector));
      },
      waitForSelector: async (selector, o) => {
        await onTarget("waitFor", selector, optionsOf(o));
        return handle(tabName, target(selector));
      },
      waitForNavigation: (o) => t("waitForNavigation", optionsOf(o)),
      waitForUrl: (pattern, o) =>
        t("waitForUrl", Object.assign({ pattern: pattern instanceof RegExp ? pattern.source : String(pattern), regex: pattern instanceof RegExp }, optionsOf(o))),
      evaluate: (fn, ...args) => t("evaluate", { source: typeof fn === "function" ? fn.toString() : String(fn), isFunction: typeof fn === "function", args }),
      setViewport: (v) => t("viewport", optionsOf(v)),
      id: async (n) => {
        await t("checkTarget", { target: { id: Number(n) } });
        return handle(tabName, { id: Number(n) });
      },
      ref: async (ref) => {
        await t("checkTarget", { target: { selector: String(ref) } });
        return handle(tabName, { selector: String(ref) });
      },
    };
    const display = (value) => call("display", { text: typeof value === "string" ? value : JSON.stringify(value, null, 2) });
    const assert = (condition, message) => {
      if (!condition) throw new Error(message || "assertion failed");
    };
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const wait = async (fn, o) => {
      const opts = typeof o === "number" ? { timeout: o } : optionsOf(o);
      const timeout = Math.min(opts.timeout ?? 10000, budget);
      const interval = opts.interval ?? 100;
      const start = Date.now();
      for (;;) {
        const value = await fn();
        if (value) return value;
        if (Date.now() - start > timeout) throw new Error(`wait() timed out after ${timeout}ms`);
        await sleep(interval);
      }
    };
    return { tab, display, assert, wait, sleep };
  };
  globalThis.__fxScope = scope;
  globalThis.__fxSerialize = (value) => {
    if (value === undefined) return null;
    if (typeof value === "string") return value;
    if (value && value.__fxTarget) return JSON.stringify(value.__fxTarget);
    try {
      return JSON.stringify(value, null, 2) ?? String(value);
    } catch {
      return String(value);
    }
  };
  return true;
})();
