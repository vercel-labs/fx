const isRecord = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

export function createFxHtmlView({ container, send, openTerminal }) {
  if (!container?.ownerDocument || typeof container.replaceChildren !== "function") {
    throw new TypeError("An HTML container is required");
  }
  if (typeof send !== "function") throw new TypeError("An interaction sender is required");
  const document = container.ownerDocument;
  const listeners = [];
  let disposed = false;
  let current;
  let submitted = false;
  let lastInput;
  let composing = false;
  let transcriptKey;

  function element(tag, className, text) {
    const node = document.createElement(tag);
    node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function listen(node, type, listener) {
    node.addEventListener(type, listener);
    listeners.push(() => node.removeEventListener(type, listener));
  }
  const root = element("section", "fx-html");
  const transcript = element("div", "fx-transcript");
  transcript.setAttribute("role", "log");
  transcript.setAttribute("aria-label", "Conversation");
  const status = element("p", "fx-status");
  status.setAttribute("role", "status");
  const interactions = element("div", "fx-interactions");
  const notices = element("div", "fx-notices");
  const commands = element("div", "fx-commands");
  commands.setAttribute("aria-label", "fx commands");
  const form = element("form", "fx-composer");
  const input = element("textarea", "fx-input");
  input.setAttribute("aria-label", "Message fx");
  input.placeholder = "Message fx";
  input.disabled = true;
  const submit = element("button", "fx-submit", "Send");
  submit.type = "submit";
  submit.disabled = true;
  const cancel = element("button", "fx-cancel", "Stop");
  cancel.type = "button";
  cancel.hidden = true;
  const error = element("p", "fx-error");
  error.setAttribute("role", "alert");
  form.append(input, submit, cancel);
  root.append(transcript, notices, status, interactions, commands, form, error);
  container.append(root);

  function action(value) {
    if (disposed) return;
    error.textContent = "";
    try {
      Promise.resolve(send(value)).catch(reportError);
    } catch (cause) { reportError(cause); }
  }
  function reportError(cause) {
    if (disposed) return;
    error.textContent = cause instanceof Error ? cause.message : "Could not send this action.";
    submitted = false;
    input.readOnly = false;
  }
  function modelAction(kind, detail = {}) {
    if (!current?.model?.active) return;
    action({ type: "model", action: kind, revision: current.revision, ...detail });
  }
  function button(label, callback) {
    const node = element("button", "fx-choice", label);
    node.type = "button";
    node.addEventListener("click", callback);
    return node;
  }
  function renderCommands() {
    commands.replaceChildren();
    const query = input.value;
    if (current?.model?.active || !query.startsWith("/") || /\s/.test(query)) return;
    for (const command of current?.commands ?? []) {
      if (!isRecord(command) || typeof command.command !== "string" || typeof command.description !== "string") continue;
      const aliases = Array.isArray(command.aliases) ? command.aliases.filter((alias) => typeof alias === "string") : [];
      if (![command.command, ...aliases].some((name) => name.startsWith(query))) continue;
      const node = button(`${command.command} ${command.description}`, () => {
        input.value = command.command + (command.accepts_payload ? " " : "");
        lastInput = input.value;
        action({ type: "input", text: input.value });
        input.focus();
        renderCommands();
      });
      commands.append(node);
    }
  }
  function sendInput() {
    if (composing || input.disabled) return;
    lastInput = input.value;
    action({ type: "input", text: input.value });
    renderCommands();
  }
  listen(input, "compositionstart", () => { composing = true; });
  listen(input, "compositionend", () => { composing = false; sendInput(); });
  listen(input, "input", sendInput);
  listen(input, "keydown", (event) => {
    if (event.isComposing || composing) return;
    if (current?.model?.active && ["ArrowUp", "ArrowDown", "Escape"].includes(event.key)) {
      event.preventDefault();
      modelAction(event.key === "Escape" ? "dismiss" : "move", event.key === "Escape" ? {} : { delta: event.key === "ArrowUp" ? -1 : 1 });
    } else if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      form.requestSubmit();
    }
  });
  listen(form, "submit", (event) => {
    event.preventDefault();
    if (input.disabled || submitted || composing) return;
    if (current?.model?.active) { modelAction("accept"); return; }
    sendInput();
    submitted = true;
    input.readOnly = true;
    action({ type: "submit" });
  });
  listen(cancel, "click", () => action({ type: "cancel" }));

  function render(snapshot) {
    if (disposed) return;
    if (!isRecord(snapshot) || snapshot.type !== "snapshot" || snapshot.version !== 1 ||
        !isRecord(snapshot.composer) || typeof snapshot.composer.text !== "string" ||
        !isRecord(snapshot.model) || !Array.isArray(snapshot.model.items) || !Array.isArray(snapshot.commands)) {
      throw new TypeError("Invalid fx interaction snapshot");
    }
    const previous = current;
    current = snapshot;
    const unsupported = typeof snapshot.unsupported_screen === "string";
    const locked = unsupported || snapshot.composer.protected === true || snapshot.permission !== null && snapshot.permission !== undefined;
    input.disabled = locked;
    submit.disabled = locked;
    const submissionAccepted = submitted && snapshot.composer.text === "";
    if (submissionAccepted || !submitted && (document.activeElement !== input || snapshot.composer.text === lastInput ||
        previous?.model?.stage !== snapshot.model.stage || previous?.model?.active !== snapshot.model.active)) {
      if (input.value !== snapshot.composer.text) input.value = snapshot.composer.text;
      submitted = false;
      input.readOnly = false;
    }
    if (snapshot.composer.protected) input.value = "";
    cancel.hidden = snapshot.busy !== true;
    status.textContent = snapshot.composer.protected ? "Complete authentication in the native terminal." : snapshot.busy ? "fx is working…" : "";
    const nextTranscriptKey = Array.isArray(snapshot.transcript) ? JSON.stringify(snapshot.transcript) : undefined;
    if (nextTranscriptKey !== undefined && nextTranscriptKey !== transcriptKey) {
      transcriptKey = nextTranscriptKey;
      const atBottom = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 32;
      const entries = snapshot.transcript.flatMap((message) => {
        if (!isRecord(message) || typeof message.role !== "string" || typeof message.text !== "string") return [];
        const entry = element("article", "fx-message");
        entry.dataset.role = message.role;
        entry.append(element("span", "fx-message-role", message.role), element("pre", "fx-message-text", message.text));
        return [entry];
      });
      transcript.replaceChildren(...entries);
      if (atBottom) transcript.scrollTop = transcript.scrollHeight;
    }
    interactions.replaceChildren();
    notices.replaceChildren();
    for (const notice of snapshot.notices ?? []) {
      if (!isRecord(notice) || typeof notice.body !== "string") continue;
      notices.append(element("p", "fx-notice", notice.body));
    }
    if (snapshot.transcript_truncated) notices.append(element("p", "fx-truncation", "Showing part of the conversation. The full history is saved by fx."));
    if (unsupported) {
      status.textContent = `The ${snapshot.unsupported_screen} screen is available in the terminal.`;
      if (typeof openTerminal === "function") interactions.append(button("Open terminal", openTerminal));
      interactions.append(button("Close screen", () => action({ type: "dismiss" })));
    }
    if (snapshot.model.active) {
      const menu = element("div", "fx-picker");
      menu.setAttribute("role", "listbox");
      menu.setAttribute("aria-label", snapshot.model.stage);
      snapshot.model.items.forEach((label, index) => {
        if (typeof label !== "string") return;
        const item = button(label, () => action({ type: "model", action: "accept", index, revision: snapshot.revision }));
        item.setAttribute("role", "option");
        item.setAttribute("aria-selected", String(index === snapshot.model.selected_index));
        menu.append(item);
      });
      if (snapshot.model.loading) menu.append(element("p", "fx-picker-status", "Loading…"));
      if (snapshot.model.failed) menu.append(element("p", "fx-picker-status", "fx could not load the model list."));
      interactions.append(menu, button("Back", () => modelAction("back")), button("Close", () => modelAction("dismiss")));
    }
    if (isRecord(snapshot.permission)) {
      const permission = snapshot.permission;
      const prompt = element("section", "fx-permission");
      prompt.setAttribute("aria-label", "Permission request");
      prompt.append(element("p", "fx-permission-label", permission.label), element("p", "fx-permission-explanation", permission.explanation));
      if (isRecord(permission.request)) {
        prompt.append(element("pre", "fx-permission-details", JSON.stringify(permission.request, null, 2)));
      }
      if (permission.truncated) prompt.append(element("p", "fx-truncation", "The action preview is truncated. Open the terminal for more detail."));
      for (const option of permission.choices ?? []) {
        if (!isRecord(option) || typeof option.label !== "string" || !Number.isInteger(option.id)) continue;
        prompt.append(button(option.label, () => action({ type: "permission", id: permission.id, choice: option.id })));
      }
      interactions.append(prompt);
    }
    renderCommands();
  }
  return {
    render,
    dispose() {
      if (disposed) return;
      disposed = true;
      for (const remove of listeners) remove();
      root.remove();
    },
  };
}
