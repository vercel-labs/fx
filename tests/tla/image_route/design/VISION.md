# Vision

## The end state

fx decides how images reach the model from one catalog fact: whether the model has vision. A model with vision gets every image inline, from the user or from a tool, through the one wire form the gateway documents for images. A model without vision gets the vision tool, or a plain explanation when no vision tool exists. A model fx cannot confirm gets no images, a notice that says so, and one more catalog check in the turn.

That decision is one pure function, `image_route.step(state, event)`, in `src/core/images/image_route.zig`. It reads no clock, environment, or global and performs no I/O. The orchestrator's turn loop is its shell: it runs the effects `step` returns and feeds their results back as events. A TLA+ model states the laws the function keeps, and Bun drivers check the real function against the model, in both directions, on every change.

## What the system is

- **One snapshot per request.** Every part of a request's image handling reads the same capability value, even when that value changes mid-turn.
- **Honest about what it withholds.** An image that does not reach the model always leaves a notice the model can act on. The user hears about it once per turn when the catalog itself is down.
- **Bounded.** One waiting request, at most two effects per step, and at most one catalog request per turn from the image decision.
- **Shared by every surface.** The CLI, the TUI, ACP, and both libfx backends run the same core.

## What it refuses to be

- **A guess.** fx sends no image to a model the catalog does not confirm, even one whose name suggests vision. Unknown means withheld.
- **A second catalog.** fx keeps no table of which models take images, and offers no setting to override the gateway. The catalog is the source of truth, and a wrong tag gets fixed there.
- **A retry loop.** The core never repeats a send, a failure, or a notice, and never asks the catalog twice in a turn.
- **Provider-aware.** The core knows support values, not provider names. Provider quirks stay in the provider code that maps a catalog to support.

## Tradeoffs it makes on purpose

| Choice | Over | Because |
| --- | --- | --- |
| Trust the `vision` tag | Also requiring `file-input`, or probing a model with a test image | The gateway defines image input as `vision`. If a vision-tagged route rejects an image, the request fails visibly instead of silently losing the image |
| Resend images with every request | Uploading once and sending references | The AI SDK prompt has no reference form. Existing caps bound every request (`request_image_budget.zig`, `image_data.requestMaxDimension`) |
| One catalog request per turn | Re-checking on every request | Bounded latency and traffic matter more than seeing a recovery a few seconds sooner. The next turn checks again |
| Ask before deciding | Deciding first and re-checking for tool images | Deciding first is what split one request across two values |
| A pure core with a thin shell | Leaving the decision inline in the orchestrator | The orchestrator cannot be model checked. A pure step with `abstract()` can be checked edge by edge against the model |
| Tell the user once per turn | Every request, or never | Every request is noise. Never hides a down catalog the user can do something about |
