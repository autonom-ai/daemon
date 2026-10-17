# Autonom Code Style

This is the working style guide for Autonom. For D, the author's current
repositories at `/home/cet/Repos/Libraries/{intuit,selenium,akashi,multidasm}`
are the primary evidence for conventions. Prefer the consistent patterns in
those repositories over generic D advice or older Autonom notes. Where the
repositories disagree, this document selects a clear local convention rather
than pretending they are uniform. The author's explicit conventions take
precedence over outlier examples in those repositories; record deliberate
Autonom-specific choices as such.

This guide describes how to write and review code; it is not permission to
reformat unrelated files. Preserve protocol behavior, ownership, and safety
invariants while improving style. Do not create abstractions, compatibility
layers, or file splits solely to satisfy a style checklist.

## Shared Principles

- Prefer direct, imperative, domain-shaped code. Keep mutable state with its
  owner. Add a type, helper, layer, or interface only when it names a real
  operation or boundary, clarifies ownership, or protects an invariant.
- Make control flow, data flow, and lifetime visible. Keep a temporary when it
  explains a transition, supports cleanup, or is reused; inline it when the
  expression is already clear.
- Use meaningful names that are brief in context. Avoid cryptic abbreviations,
  repeated context, and names that disguise the real operation.
- Comments explain non-obvious invariants, protocol constraints, safety
  boundaries, and surprising behavior. Do not narrate ordinary statements.
- Prefer real domain types and real behavior in tests. Keep test fixtures at
  the boundary they support; a simulated peer is not evidence of compatibility
  with an installed product.

## D

### Names and Casing

- Types, classes, structs, interfaces, exception types, and enum types use
  `PascalCase`.
- Functions, methods, fields, parameters, locals, and ordinary compile-time
  values use `camelCase`.
- Enum members use `PascalCase`, even when their serialized values use
  lowercase or snake case: `FinishReason.MaxTokens = "max_tokens"`.
- Locally named D identifiers, including constants, use `camelCase`. Name a
  limit `frameLimit`, a file `wakesFile`, and a timeout `pollInterval`, whether
  declared with `enum`, `immutable`, or as a field. Do not create
  `UPPER_SNAKE_CASE` D constants. The reference repos contain a few
  spec-shaped exceptions (ISA encodings and W3C keys); do not copy those
  outliers into Autonom. Preserve an external symbol's spelling only when it
  is imported from or required by that external interface.
- Name template functions in `camelCase` and templates that define data types
  in `PascalCase`. Use meaningful template parameters; conventional type
  parameters such as `T`, `K`, and `V` may be short. Do not use capitalized
  snake-case names for ordinary template values or locals.
- Use one-letter names for loop indices (`i`, `j`, `k`) or formulaic variables.
  Short domain terms such as `id`, `io`, and `db` are fine when unambiguous.
  Other one- or two-letter names need an established, meaningful expansion
  (`ep` for endpoint, for example); do not abbreviate `damageType` to `dt`.
- Prefer the shorter name when context makes it clear (`family`, not
  `currentFamily`). Fields should be more descriptive than locals when both
  name the same concept (`arguments`, not `args`, for persistent state).
- Use a domain-specific `foreach` name when one is obvious. For a raw byte or
  generic current item, prefer `val` or a type-specific name over `value`.
  `key, value` remains a clear and established pair for associative-array
  iteration.
- Avoid type names that repeat or collide with an established domain type.
  Name the concept represented by the type; for example, use `Instance` for
  a live connection record when `Session` already names the backend domain
  object, rather than introducing an ambiguous `LiveSession`.
- Name a constructed or accumulated return value `ret`. Return a direct
  expression directly; do not add a local just to call it `ret`.
- Use lowercase D module/file names without underscores. Name files after the
  domain they own; use a directory for a real subdomain. `package.d` is a
  deliberate package facade, not a file every directory needs.

### Types, Constants, and Inference

- Use `struct` for value records, options, results, and snapshots. Use `class`
  for identity-bearing objects, services, shared mutable handles, and
  inheritance/interface implementations. Choose based on ownership and
  mutation, not size.
- Give ordinary locals explicit types. Do not use `auto` for a routine result
  whose type is short and nameable. Use inference only for unnameable
  compiler-generated types or template-dependent types. For associative-array
  lookups, spell the pointer type when it is clear (`Session* found = id in
  sessions`). Use `typeof(expression)` for an unnameable result when that is
  clearer.
- A wire-facing enum has an explicit base type and explicit wire values.
  Keep members `PascalCase`; use `final switch` when a switch must be
  exhaustive.
- Use `const`, `immutable`, `shared`, `__gshared`, `ref`, `inout`, `scope`,
  `return`, `pure`, `nothrow`, `@safe`, `@trusted`, and `@nogc` only for their
  actual compiler-enforced or API semantics. They are not decoration.
- Declare `static` explicitly when a method does not depend on an instance.
- Prefer a direct return when one expression is sufficient. Use `ret` for a
  value assembled across steps. A temporary is appropriate for a checked
  lookup, a resource with `scope(exit)`, a value protected by a lock, or a
  value used more than once.

### Modules, Imports, and Visibility

- Put the `module` declaration first, then imports, then declarations.
- Group imports as project modules, external dependencies, then runtime
  modules. Separate the groups with one blank line. Within groups, keep imports
  organized and consistent with the surrounding module; selective imports are
  preferred when they clarify ownership or avoid pulling in a broad namespace.
  Broad imports from cohesive modules such as `std.file` or `std.process` are
  acceptable when genuinely useful. Within the runtime group, put `core.*`
  before `std.*`, matching Autonom's established ordering.
- Keep imports at module scope. Put conditional dependencies in the relevant
  `version` block; do not add local imports to ordinary function bodies.
- Use D access sections (`private:`, `package:`, `package(name):`,
  `protected:`, `public:`) when they change visibility. Declarations are
  public by default: do not add `public:` just to repeat the default, or repeat
  a visibility scope without changing it. Some reference modules use
  `public:` to mark a public API section after private/package members; Autonom
  does not need that label when the declaration is already public by default.
- Use `private:`, `package:`, or qualified `package(name):` to narrow access
  where needed. `protected:` is for a real subclass seam, not as a synonym for
  package access. Use `public:` only when it intentionally overrides an
  enclosing narrower scope.
- Group members by access instead of repeatedly switching sections. A common
  class order is private/package state and helpers, then protected members,
  then public API. Public API followed by a trailing private helper section is
  also established. Within a class, put fields before methods and the
  constructor after the fields.
- Keep `package.d` modules to `public import` re-exports. Put enums and
  module-level constants before their consumers; constants specific to one
  type may live in that type's access section.
- Keep related types together when they share an owner. Split a file when
  ownership or responsibility becomes unclear, not at an arbitrary line
  count. A cohesive class may be several hundred lines; a file above roughly
  800 lines deserves review, especially when it contains multiple owners.

### Braces, Functions, and Control Flow

- Use four-space indentation and Allman braces for declarations and scoped
  control flow. Put the body on the following line.
- Omit braces only when a scoped statement has one non-nested body statement
  that fits on one physical line. If the body statement wraps across lines or
  contains nested scoped control flow, use braces. A braced outer block
  remains braced even if its nested statement is a single line.
- Put `else`, `catch`, and `finally` on their own line immediately after the
  preceding `}`. Write an empty block as `{ }` on one line.
- Use `=>` for a function or accessor only when its complete expression fits
  on one physical line. If the expression needs wrapping, use a braced body
  with an explicit `return`. Intuit and Selenium have occasional wrapped
  forwarding expressions; Autonom follows the stricter single-line form.
- For a delegate literal with a block body, put `{` on the same line as the
  delegate introducer and put its statements on following lines. An
  expression-lambda `=>` is allowed only when the entire expression fits on
  one physical line. If it would wrap, write a normal delegate block instead.
  Do not put a statement body on one line.
- In a `switch`, align `case` labels with the `switch`; indent their bodies.
  Keep cases visually distinct when the body is substantial.
- Use `scope(exit)` and `scope(failure)` without a space, matching Autonom's
  established D usage.
- Do not write unbounded sentinel loops such as `for (;;)` or `while (true)`.
  Give a loop a meaningful continuation predicate or restructure the control
  flow so its termination is visible in the loop condition.

### Whitespace and Line Layout

- Separate declarations with exactly one blank line. Do not leave blank lines
  immediately inside braces or use two blank lines between adjacent
  declarations.
- Use blank lines to separate logical steps inside a function. In particular,
  separate an early `return`, `throw`, `continue`, or `break` from the next
  step, and separate a completed braced statement from the following step.
  Consecutive related guard checks may remain together. Do not add a blank
  before `else`, `catch`, `finally`, or a closing brace.
- Put no spaces around string concatenation `~`, range `..`, the operand of
  `cast(Type)value`, or `$-n`: `"path/"~name`, `items[0..$-1]`. Put one space
  around other binary operators, including arithmetic inside indexes and
  ranges: `items[index + 1..$]`.
- Put one space after commas and after the colon in associative-array entries;
  do not pad operators or columns for visual alignment.
- Keep a ternary expression on one line only when it is short and immediately
  readable. For a longer ternary, put each branch marker at the start of its
  own line:

  ```d
  string reason = hasReason
      ? result["stopReason"].str
      : null;
  ```

  Do not leave `?` or `:` at the end of an overlong condition or branch.
- Keep short literals and calls compact when that aids reading. When an array
  or associative-array literal spans lines, put one element per line. Do not
  add trailing commas in D literals. A flat literal of one or two entries may
  stay on one line; nesting or a long value is a reason to expand it.
- Prefer a line length near or below 120 columns. Wrap when it improves
  scanning; do not split a simple expression into noisy fragments.
- Do not leave trailing whitespace, including on blank lines.

### JSON and Structured Data

- Use a domain struct with a `toJSON()` method when the data has a stable
  domain shape and behavior.
- `JSONValue([ ... ])` is a normal way to express a JSON object, including
  nested arrays and objects. Keep the literal when it presents the data more
  clearly than separate assignments. The reference code commonly uses both
  small inline objects and larger multiline literals.
- A multiline JSON literal is fine inside a braced function body. `=>` bodies
  are for one-line expressions; do not make a multiline JSON construction an
  expression-bodied function.
- Use `JSONValue.emptyObject`/`emptyArray` and assign or append values when
  construction is conditional, incremental, or clearer as sequential steps:

  ```d
  JSONValue server = JSONValue.emptyObject;
  server["name"] = JSONValue(mcpServerName);
  server["command"] = JSONValue("python3");

  JSONValue args = JSONValue.emptyArray;
  args.array ~= JSONValue(mcpServerPath());
  server["args"] = args;
  ```

- Use named intermediate objects when they clarify the shape or avoid
  repeating work; do not mechanically expand a clear literal or introduce a
  generic JSON builder.
- Add a helper only when it removes real duplication, names a meaningful
  domain operation, or protects an invariant. A reused helper such as
  `optionParams` is useful; do not extract a one-use helper just to wrap a
  constructor or a direct call.

### Accessors and Attributes

- Use a property-shaped accessor for field-like state and a verb-shaped method
  for an action. Select one clear call shape for each API.
- `@property` is allowed and is used in Selenium; it is neither required for
  every accessor nor prohibited. Use it when property syntax accurately
  represents the API. Plain accessors and intentional `ref` accessors are also
  established in Intuit and Akashi.
- Return `ref` only when caller mutation or lazy access to owned storage is
  part of the contract. By-value access is the default when exposing owned
  state.
- Prefer UFCS when a free function is naturally an operation on its first
  argument: write `connection.sendLine(request)` rather than
  `sendLine(connection, request)`. Do not force UFCS onto functions that do
  not read naturally as receiver operations.
- Use `const` on methods that do not mutate state and on fields fixed after
  construction. Keep struct fields mutable when assignment or value semantics
  require it. Use `override` for actual overrides.
- Use template constraints to express real type requirements. Use D's
  `if (is(...))` form. Use `@disable`, `version`, `extern(C)`, `lazy`, and
  lifetime attributes only where their language semantics are intended and
  verified.
- `__gshared` is not inherently pointless: it makes storage process-global
  rather than thread-local. Use it only when that is the required ownership
  model, and synchronize mutable access.

### Comments, Errors, and Tests

- Use `///`/Ddoc for public API contracts, especially parameters, return
  values, errors, lifetimes, and protocol behavior that callers need to know.
  Use `//` for implementation rationale, specification references, and
  non-obvious invariants. Application code need not mimic library-wide Ddoc
  density.
- Avoid decorative rulers and boilerplate headings. A short marker is
  acceptable when it names a genuine group in a long table, grammar, or
  dispatch structure.
- TODO/FIXME comments must identify a concrete follow-up. Do not keep
  commented-out code or unused members "just in case."
- Throw the domain exception that matches the failure. In the daemon,
  `InvalidInputException`, `ConflictException`, and `BackendException` define
  caller-visible HTTP outcomes; use bare `Exception` for failures without a
  more accurate domain type. Catch broadly only at a deliberate boundary
  (thread/result funnel, parse translation, or best-effort cleanup). Swallow
  failures only when they are genuinely best-effort; explain a swallowed
  failure when it could obscure a security or ownership invariant.
- Name tests for behavior and use domain objects and the project's real test
  runner. Prefer focused tests organized by domain. Use `@Name`,
  `@ShouldFailWith`, and scoped cleanup where appropriate. Model simulation is
  acceptable at the model boundary; it does not replace installed-peer or
  live-product validation.

## TypeScript

- Use four-space indentation, Allman braces, double-quoted strings/imports,
  semicolons, `camelCase` values/functions, and `PascalCase` types.
- Use `const` unless reassignment is required. Local type inference is normal;
  use explicit types at stable API boundaries when they clarify the contract.
- Use `unknown` for untrusted input and narrow it. Keep `any` at genuinely
  dynamic host/vendor boundaries.
- Keep imports at module scope except for intentional dynamic imports. Use the
  existing `node:test` and `node:assert/strict` test conventions.

## Python

- Follow Python conventions: four-space indentation, `snake_case` functions
  and values, `PascalCase` types, and uppercase module constants.
- Keep subprocesses, output, credentials, environment forwarding, and
  exception behavior bounded and intentional. Security-sensitive hooks fail
  closed when required authentication or validation fails.

## Reference Evidence

The selected conventions are grounded in the current source of:

- [Intuit `IRouter` and OpenRouter](../../Libraries/intuit/source/intuit/router/package.d),
  [message types](../../Libraries/intuit/source/intuit/context/message.d), and
  [JSON tests](../../Libraries/intuit/source/tests/provider/openai.d).
- [Selenium `PrintOptions`](../../Libraries/selenium/source/selenium/driver/print.d),
  [driver and bridge](../../Libraries/selenium/source/selenium/driver/package.d),
  and [test fixtures](../../Libraries/selenium/source/tests/common.d).
- [Akashi request client](../../Libraries/akashi/source/akashi/request.d),
  [page accessors](../../Libraries/akashi/source/akashi/page.d), and
  [text AST](../../Libraries/akashi/source/akashi/text/ast.d).
- [Multidasm encoding and instruction types](../../Libraries/multidasm/source/multidasm/amd64/encoding.d)
  and [AMD64 instruction implementation](../../Libraries/multidasm/source/multidasm/amd64/package.d).

The repositories differ in a few details (for example, `@property`, the order
of `core.*` and `std.*` imports, and spacing in `scope(exit)`). The rules above
choose one consistent Autonom convention and preserve exceptions only where
the language or external contract requires them.
