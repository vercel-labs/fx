# API and Maintainability Design

Read this reference when adding public declarations, changing module boundaries,
reviewing architecture, naming types and functions, or refactoring a Zig codebase.

## Public API shape

- Treat `pub` as a compatibility decision. Default to private and expose only the
  operations callers need.
- Prefer behavior-oriented APIs over exposing mutable representation. Returning a slice
  into internal mutable storage couples callers to invalidation and layout details.
- Return the simplest type that communicates the result. Do not return a large context
  object when the caller needs one value.
- Document ownership, borrowing duration, allocation, blocking behavior, errors,
  thread-safety, cancellation, bounds, and invalidation when relevant. These are parts of
  the type contract that Zig's type system cannot always express.
- Use an options struct when defaults matter or several parameters have similar types.
  Keep required parameters direct when that makes invalid calls impossible.
- Keep shared helpers narrow. If one new caller needs exceptional semantics, add a
  focused helper unless the broader contract is correct for every existing caller.
- Avoid abstraction layers that merely rename another API. Add a layer when it owns a
  policy, invariant, translation boundary, or test seam.

## Module boundaries

- Give each module a clear owner and responsibility. A composition root wires modules;
  it should not become the home of unrelated feature state or leaf behavior.
- Keep dependency direction understandable. Domain code should not depend on UI,
  transport, logging presentation, or process-global state merely for convenience.
- Separate parsing, validation, state mutation, persistence, transport, and rendering
  when they change for different reasons. Do not split tiny code mechanically; split
  where the boundary produces a clearer contract.
- Centralize orchestration and keep leaf transformations as pure as practical. This
  makes error handling, state transitions, and tests easier to inspect.
- Place state in the runtime or object that owns its lifecycle. Avoid unrelated global
  mutable state and generic catch-all contexts.
- Keep files and functions small enough to understand as a unit, but do not enforce an
  arbitrary line limit. Size is a review signal: split when multiple responsibilities,
  lifetimes, or abstraction levels have accumulated.

## Naming and layout

- Follow the repository's naming rules first. When it has none, follow the Zig standard
  style: type-producing declarations and types use `TitleCase`; ordinary functions use
  `camelCase`; variables and fields use `snake_case`; namespace files use `snake_case`.
- Name by role and invariant, not implementation accident. Avoid vague containers such
  as `Manager`, `Data`, `Utils`, or `Context` unless the name accurately describes a
  specific domain responsibility.
- Include qualifiers that prevent confusion: units, ownership, encoding, coordinate
  system, or normalized/raw state.
- Avoid redundant namespace repetition such as `parser.ParserResult` when
  `parser.Result` is equally clear.
- Let `zig fmt` decide mechanical formatting. Prefer trailing commas in multiline
  literals and calls so formatting and diffs remain stable.
- Comments should explain why a constraint exists, why an apparently simpler approach
  is unsafe, or what external contract is being preserved. Do not narrate obvious code.

## Change discipline

- Scope a change to one coherent reason. Keep drive-by renames, formatting, and adjacent
  refactors separate unless required by the requested behavior.
- Before changing a shared contract, inspect every caller and state which previous
  assumptions remain valid.
- Preserve observable behavior during refactors. Add characterization tests first when
  behavior is unclear.
- Remove obsolete variants after intentionally broadening a contract; otherwise the API
  presents multiple ways to do the same thing.
- Log or otherwise surface dropped user-visible or in-flight state. Silent loss makes
  intermittent failures difficult to diagnose.

## Review questions

- Can a caller tell who owns every returned pointer or slice?
- Can invalid combinations of fields be constructed?
- Does the error set describe the abstraction rather than its current implementation?
- Is allocation or blocking hidden behind an innocent-looking accessor?
- Does a public declaration expose representation that callers do not need?
- Is a generic abstraction actually used with meaningfully different types?
- Did a focused change broaden behavior for unrelated callers?
- Would a future enum variant, larger input, or different allocator fail visibly?
