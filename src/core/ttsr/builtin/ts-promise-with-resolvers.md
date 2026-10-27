---
description: Use Promise.withResolvers() instead of new Promise() constructor
scope: "tool:shell"
interruptMode: never
match:
  if: { lang: [ts, tsx, mts, cts, js, jsx, mjs, cjs] }
  then:
    regex: 'new Promise\('
    in: code
  else:
    all:
      - regex: 'new Promise\('
        in: [code, string]
      - llm: "Does this content actually construct a promise with `new Promise(...)`, rather than quoting or discussing that constructor?"
---

Prefer `Promise.withResolvers()` over `new Promise((resolve, reject) => ...)`: linear control flow; typed resolvers without callback nesting.

## Basic operation

```typescript
// Bad
function delay(ms: number): Promise<void> {
	return new Promise(resolve => {
		setTimeout(resolve, ms);
	});
}

// Good
function delay(ms: number): Promise<void> {
	const { promise, resolve } = Promise.withResolvers<void>();
	setTimeout(resolve, ms);
	return promise;
}
```

## Event-based completion

```typescript
// Bad
function waitForEvent(emitter: EventEmitter, event: string): Promise<unknown> {
	return new Promise((resolve, reject) => {
		emitter.once(event, resolve);
		emitter.once("error", reject);
	});
}

// Good
function waitForEvent(emitter: EventEmitter, event: string): Promise<unknown> {
	const { promise, resolve, reject } = Promise.withResolvers<unknown>();
	emitter.once(event, resolve);
	emitter.once("error", reject);
	return promise;
}
```

## Stored resolver

```typescript
class Gate {
	#promise: Promise<void>;
	#resolve: () => void;

	constructor() {
		const { promise, resolve } = Promise.withResolvers<void>();
		this.#promise = promise;
		this.#resolve = resolve;
	}

	open(): void { this.#resolve(); }
	wait(): Promise<void> { return this.#promise; }
}
```

Constructor only if an API specifically requires executor form.
