(globalThis[Symbol.for("proto-fx.browser")] ??= (() => {
  "use strict";
  // Selector resolution for the browser tool, installed once per document in
  // the page's main world. Selectors follow puppeteer's query handlers:
  // CSS, text/, aria/, xpath/, pierce/, and aria-ref=eN from ariaSnapshot().
  const implicitRole = (el) => {
    const tag = el.tagName.toLowerCase();
    const type = (el.getAttribute("type") || "").toLowerCase();
    switch (tag) {
      case "a": return el.hasAttribute("href") ? "link" : "generic";
      case "button": return "button";
      case "select": return el.multiple || el.size > 1 ? "listbox" : "combobox";
      case "textarea": return "textbox";
      case "option": return "option";
      case "img": return "img";
      case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
      case "input":
        if (["button", "submit", "reset", "image"].includes(type)) return "button";
        if (type === "checkbox") return "checkbox";
        if (type === "radio") return "radio";
        if (type === "range") return "slider";
        if (type === "number") return "spinbutton";
        if (type === "search") return "searchbox";
        return "textbox";
      default: return "";
    }
  };
  const roleOf = (el) => (el.getAttribute("role") || "").split(/\s+/)[0] || implicitRole(el);
  const textOf = (el) => (el.innerText ?? el.textContent ?? "").replace(/\s+/g, " ").trim();
  const nameOf = (el) => {
    const label = el.getAttribute("aria-label");
    if (label) return label.trim();
    const by = el.getAttribute("aria-labelledby");
    if (by) {
      const text = by.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean).map(textOf).join(" ").trim();
      if (text) return text;
    }
    if (el.labels && el.labels.length) return Array.from(el.labels).map(textOf).join(" ").trim();
    if (el.tagName === "INPUT" && ["button", "submit", "reset"].includes(el.type)) return (el.value || "").trim();
    const alt = el.getAttribute("alt") || el.getAttribute("title");
    if (alt) return alt.trim();
    const role = roleOf(el);
    if (["textbox", "searchbox", "combobox", "spinbutton"].includes(role)) return (el.getAttribute("placeholder") || "").trim();
    return textOf(el);
  };
  const visible = (el) => {
    if (!el.isConnected) return false;
    const style = getComputedStyle(el);
    if (style.visibility === "hidden" || style.display === "none") return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };
  const deepAll = (root, css, out) => {
    for (const el of root.querySelectorAll(css)) out.push(el);
    for (const host of root.querySelectorAll("*")) if (host.shadowRoot) deepAll(host.shadowRoot, css, out);
    return out;
  };
  const allElements = () => deepAll(document, "*", []);
  const byText = (text) => {
    const wanted = text.trim();
    const lower = wanted.toLowerCase();
    const rank = (el) => {
      if (["SCRIPT", "STYLE", "NOSCRIPT", "HTML", "HEAD", "TITLE"].includes(el.tagName)) return 0;
      const own = el.tagName === "INPUT" ? (el.value || "") : (el.textContent || "").replace(/\s+/g, " ").trim();
      if (!own) return 0;
      if (own === wanted) return 3;
      if (own.includes(wanted)) return 2;
      return own.toLowerCase().includes(lower) ? 1 : 0;
    };
    // The deepest matching element: a match none of whose children match.
    let best = null;
    let bestKey = null;
    for (const el of allElements()) {
      const r = rank(el);
      if (!r) continue;
      if (Array.from(el.children).some((child) => rank(child) > 0)) continue;
      const key = [visible(el) ? 1 : 0, r, -(el.textContent || "").length];
      if (!bestKey || key[0] > bestKey[0] || (key[0] === bestKey[0] && (key[1] > bestKey[1] || (key[1] === bestKey[1] && key[2] > bestKey[2])))) {
        best = el;
        bestKey = key;
      }
    }
    return best;
  };
  const byAria = (spec) => {
    const match = /^(.*?)(?:\[\s*role\s*=\s*["']?([^"'\]]+)["']?\s*\])?$/.exec(spec.trim());
    const name = (match[1] || "").trim();
    const role = (match[2] || "").trim();
    let fallback = null;
    for (const el of allElements()) {
      if (role && roleOf(el) !== role) continue;
      if (name && nameOf(el) !== name) continue;
      if (!name && !role) continue;
      if (visible(el)) return el;
      fallback ??= el;
    }
    return fallback;
  };
  const byXpath = (expr) => {
    const result = document.evaluate(expr, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
    const node = result.singleNodeValue;
    return node && node.nodeType === 1 ? node : node?.parentElement ?? null;
  };
  const refOf = (selector) => {
    const s = selector.trim();
    for (const prefix of ["aria-ref=", "aria-ref/", "ariaref/"]) {
      if (s.startsWith(prefix)) return /^e\d+$/.test(s.slice(prefix.length).trim()) ? s.slice(prefix.length).trim() : "";
    }
    const bare = /^@?(e\d+)$/.exec(s);
    return bare ? bare[1] : null;
  };
  const resolve = (selector) => {
    const ref = refOf(selector);
    if (ref !== null) {
      if (!ref) throw new Error(`malformed aria ref selector ${JSON.stringify(selector)}`);
      const aria = globalThis[Symbol.for("proto-fx.aria")];
      if (!aria) throw new Error(`aria ref ${ref} is unknown here; call tab.ariaSnapshot() after the last navigation`);
      const el = aria.resolveAriaRef(ref);
      if (!el) throw new Error(`aria ref ${ref} is stale; call tab.ariaSnapshot() again`);
      return el;
    }
    if (/:has-text\(|:visible\b|>>/.test(selector) && !/^(text|aria|xpath|pierce)\//.test(selector))
      throw new Error(`Playwright-only selector ${JSON.stringify(selector)} is not supported; use text/..., aria/..., CSS, or xpath/...`);
    if (selector.startsWith("text/")) return byText(selector.slice(5));
    if (selector.startsWith("aria/")) return byAria(selector.slice(5));
    if (selector.startsWith("xpath/")) return byXpath(selector.slice(6));
    if (selector.startsWith("pierce/")) return deepAll(document, selector.slice(7), [])[0] ?? null;
    return document.querySelector(selector);
  };
  return { resolve, nameOf, roleOf, textOf, visible };
})())
