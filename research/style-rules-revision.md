# Code Style Rules - Replacement Draft

This is a complete replacement draft for the older global rules at
`~/.codeium/windsurf/memories/global_rules.md`. It is research material in
this repository; it has **not** modified or replaced that external file.

The goal is consistent, readable code that feels native to its language and
to the repositories it belongs to. These are defaults, not reasons to fight
the compiler, a public API, a tested protocol, or a clear local convention.

## Precedence

When guidance differs, use this order:

1. Language and compiler semantics.
2. The explicit request and its compatibility/safety requirements.
3. Current project-specific instructions that apply to the code being changed.
4. The established style of the surrounding module and repository.
5. These cross-repository defaults.

Do not follow a stale guide over the code and tests it no longer describes.
When a repository uses a different language or has a well-established local
idiom, follow that idiom rather than mechanically applying rules from another
language. Do not reformat unrelated code just to make a file match this draft.

## Shared Principles

- Prefer direct, domain-shaped code. Keep state with its owner; add a type,
  layer, helper, interface, or wrapper when it makes an actual boundary clearer
  or protects an invariant, not to create indirection for its own sake.
- Name things for their role and keep names brief when context makes them
  unambiguous. Avoid cryptic abbreviations; familiar terms such as `id`, `io`,
  `db`, and `args` are fine when they mean exactly that.
- Make control flow and ownership visible. Do not remove a temporary when it
  makes lifetime, mutation, error handling, locking, or a meaningful value
  transition easier to see.
- Prefer a direct expression when it is as clear as a temporary. Keep a named
  return accumulator when it describes constructed output or makes the return
  path easier to read.
- Comments explain a non-obvious invariant, protocol constraint, safety
  boundary, or surprising behavior. Do not restate the code in comments, add
  decorative separators, or leave speculative notes as permanent guidance.
- Tests should name the behavior under test and use the project's real domain
  types and test runner. Keep fixtures at the boundary they support; do not
  synthesize product UI when a test claims to verify a real product surface.

## D

### Modules and Imports

- Put the `module` declaration first, followed by imports and then
  declarations.
- Group project modules first, external library modules next, and D runtime or
  standard-library modules after them. A blank line between groups is useful.
- Use selective imports when they clarify ownership or avoid collisions.
  Existing D code also uses broad imports from cohesive modules such as
  `std.file`; do not expand every convenient import mechanically.
- Keep imports at module scope by default. A local import is reasonable for a
  dependency that is genuinely conditional or limited to a test/helper path;
  do not scatter local imports merely to avoid organizing module dependencies.
- Use lowercase D module filenames that describe the module. A directory is
  appropriate when it represents a real subdomain; `package.d` is an explicit
  package module/facade, not a required file for every folder. Do not rename
  files only to satisfy a blanket rule about underscores.

### Names and Types

- Name data types, classes, structs, interfaces, and exception types in
  `PascalCase`.
- Name functions, methods, fields, parameters, and ordinary locals in
  `camelCase`.
- Short names are fine when conventional and unambiguous: loop indices such
  as `i`/`j`, template parameters such as `T`/`K`/`V`, and domain terms such as
  `id` or `db`. Avoid unexplained abbreviations, not short names categorically.
- Name enum members in `PascalCase`, matching the dominant Autonom D style.
  Give the enum type a `PascalCase` name.
- Use descriptive type-template parameters when they are part of a nontrivial
  public API. Conventional short parameters such as `T`, `K`, and `V` are
  appropriate for generic types and algorithms.
- Use uppercase names for established compile-time limits and configuration
  constants when that is the surrounding module's convention. Do not uppercase
  a runtime value merely because it is initialized with a literal; anonymous
  enum constants in sibling code also use lower camel case.
- `ret` is a familiar name for an explicit return accumulator or a constructed
  result. It is not mandatory when a function returns an expression directly,
  and it is not a reason to introduce a needless local.
- A private backing field may use a leading underscore when it is wrapped by
  an accessor and direct access could bypass an invariant (`_session` beside
  `session`, for example). Ordinary private state can use normal `camelCase`;
  do not prefix every field.
- Prefer explicit domain types when they make ownership or API meaning clear.
  Use `auto`/inference when the type is genuinely verbose, template-derived, or
  evident from the expression. There is no blanket ban on inference.
- Use `static` when a member belongs to the type/module and does not depend on
  an instance. This is a semantic distinction, not a formatting checklist.

### Visibility and Scope

D access labels (`private:`, `package:`, `protected:`, `public:`) are lexical
visibility sections. A label applies to following declarations in the current
module or aggregate until another visibility label or the enclosing scope
ends. D defaults to public visibility when no protection is specified. Use
sections to show who owns an API instead of relying on that default or
repeating a modifier on every declaration.

| Access | Use |
| --- | --- |
| `private:` | Module-internal helpers and state that are not part of the shared API. In D, `private` is module-scoped, not a C++-style guarantee that only the declaring class can see the member; another declaration in the same module may access it. |
| `package:` | Internal APIs shared by code in the package. Use a qualified form such as `package(daemon.interop):` when access belongs to a specific package rather than the broader default package boundary. This is narrower and more precise than making the member public. |
| `protected:` | A real subclass extension point. D also permits access within the declaring module; unrelated callers in other modules cannot use it. Do not use it as a synonym for package-private visibility. |
| `public:` | The intentional caller-facing API. Keep this surface small and comprehensible. |

Prefer a narrow internal section followed by the visible API, as in
`Profile` and `Session`; put `protected:` members where the subclass seam is
obvious. Existing Selenium code places some package helpers after public
methods, so section order should serve the file's ownership boundary rather
than become a mechanical rule. An accessor and its setter are separate
declarations and may have different visibility when read and write access
are intentionally different.

Do not confuse access visibility with D's `scope` lifetime features:

- `scope(exit)`, `scope(success)`, and `scope(failure)` are lexical cleanup
  guards. Use the matching guard for deterministic resource release or
  rollback; `exit` runs on either outcome, while `success`/`failure` express
  the corresponding exit path.
- `scope` used as a variable/parameter storage class is an ownership/lifetime
  constraint, not an access level. Use it only when the compiler-enforced
  non-escape/lifetime contract is intended and understood for the project's
  compiler version.
- A `private:` or `package:` block controls visibility. It does not clean up,
  shorten object lifetime, or replace a `scope` guard.
- The lifetime/escape rules for the `scope` storage class depend on D's scope
  safety implementation and compiler settings; verify the active compiler
  version and safety flags instead of assuming that `scope` means stack
  allocation or behaves like a visibility label.

Autonom uses qualified package access for shared binders and internal
functions, and uses `scope(exit)`/`scope(failure)` for file handles and
rollback. Examples: [`Profile`](../source/daemon/agent/profile.d#L25-L53),
[`Session`](../source/daemon/interop/session.d#L193-L230),
[`Execution`](../source/daemon/interop/execution.d#L302-L361), and
[`atomicWrite`](../source/daemon/storage.d#L19-L48).

### Accessors, `@property`, and UFCS

Use an accessor when it represents a named property of an object. Use a
verb-shaped method when the operation is an action.

- `@property` is appropriate for an intentional field-like getter or setter.
  It is a function attribute, not a field declaration or a requirement to
  wrap every member.
- A getter has no value parameter; a setter accepts the assigned value. D
  accessors are separate function declarations: mark each overload whose
  call should use property syntax. Use a `const` getter when it can be read
  from a const object.
- Getter and setter visibility need not match: each overload is a separate
  declaration and belongs in its own visibility section. A public getter with
  a private setter, for example, permits reads from another module while
  restricting writes to the defining module under D's module-scoped
  `private` rule. This shape was compile-checked with LDC 1.42; use it only
  when one-way mutation is an intentional API boundary.
- Getter/setter pairs with the same name form a read/write property. A
  read-only property may expose only a getter. A setter can validate, normalize,
  or synchronize state. If setting the property performs a surprising or
  important external action, document that contract and cover it in tests.
- `@property` does not mean "pure, cheap, or incapable of failure." Selenium
  has setters that validate values and timeout accessors that issue remote
  WebDriver requests. Keep the property name field-like and let the API
  documentation make non-obvious cost or failure behavior clear.
- A `ref` return is a mutable alias to the referenced storage, not a copy.
  Use it only when direct caller mutation is part of the intended contract and
  cannot bypass an invariant. By-value accessors are the safer default for
  owned state.
- A property-like zero-argument function without `@property` is valid in
  established D code: Autonom's `Profile.session` and Intuit's router
  accessors are examples. `@property` is also a real, well-used option in
  Selenium. Choose deliberately; do not ban it or decorate every getter
  automatically.
- Use UFCS when a free function naturally extends its first argument or when
  it makes a domain operation easier to read. Use parentheses for actions and
  ordinary queries whose method contract should remain explicit. Do not turn
  every helper into UFCS, and avoid relying on a property-like function name
  when a real field or another overload makes resolution unclear.
- Keep one obvious call style for each accessor shape within an API. For
  example, an annotated getter/setter pair uses `value.name` and
  `value.name = newName`; an intentionally unannotated getter plus a
  method-shaped setter may use `value.name` and `value.name(newName)`. Avoid
  making a read/write pair ambiguous with a real field or unrelated overload.

Examples that show the available shapes:

- [`IRouter`](../../Libraries/intuit/source/intuit/router/package.d#L19-L64)
  exposes getter/setter overloads for `active` and `ref` accessors for
  `name`, `tools`, and `context`; its accessors are not annotated with
  `@property`.
- Selenium's [`Driver.Timeouts`](../../Libraries/selenium/source/selenium/driver/package.d#L35-L82)
  uses annotated getters and `void` setters, while
  [`PrintOptions`](../../Libraries/selenium/source/selenium/driver/print.d#L39-L153)
  uses annotated getters and validating setters that return the assigned value.
- Selenium's [`Window`](../../Libraries/selenium/source/selenium/driver/package.d#L517-L590)
  uses properties for position/rectangle state and ordinary methods such as
  `close`, `resize`, and `switchTo` for actions.

These examples deliberately do not impose one property implementation on all
APIs. They share one criterion: the call shape should match the caller's
mental model.

### Evidence Across the Reference Repositories

These rules reflect recurring idioms, not a claim that every repository uses
one uniform syntax:

- **Autonom** uses visibility sections and qualified package access for real
  internal sharing. `Profile` separates `private:`, `package(daemon.agent):`,
  and `public:`; `Session` similarly limits execution binding to
  `daemon.interop`. Its `session()` accessor is called without parentheses
  even though it is not annotated `@property`
  ([`Profile`](../source/daemon/agent/profile.d#L25-L53),
  [`Session`](../source/daemon/interop/session.d#L193-L230)).
- **Intuit** exposes `ref` accessors and overloads `active()` /
  `active(string)` without `@property`. It also returns `ref Context` from
  mutating chainable methods. This is evidence for intentional reference
  access, not a mandate that every accessor return `ref`
  ([`IRouter`](../../Libraries/intuit/source/intuit/router/package.d#L19-L64),
  [`Context`](../../Libraries/intuit/source/intuit/context/package.d#L31-L62)).
- **Selenium** explicitly annotates paired properties. Some setters validate
  local configuration and return the assigned value; timeout setters make a
  remote request before updating local state. Selenium also mixes these with
  ordinary no-parentheses methods in its nested `window` API, so the property
  decision belongs to each API member, not to the whole class
  ([`Driver.Timeouts` and `Window`](../../Libraries/selenium/source/selenium/driver/package.d#L35-L82),
  [`PrintOptions`](../../Libraries/selenium/source/selenium/driver/print.d#L39-L153)).
- **Webull SDK** uses `ref` lazy accessors for `Account.profile()` and
  `balance()` without `@property`; a package-visible constructor and state
  separate those internals from `public:` APIs. `Client` is explicitly a
  `static class` with a private helper section
  ([`Account`](../../Libraries/webull-sdk/source/webull/account/account.d#L29-L105),
  [`Client`](../../Libraries/webull-sdk/source/webull/client.d#L43-L50),
  [`Client.checkAndParse`](../../Libraries/webull-sdk/source/webull/client.d#L260-L282)).
- **Akashi** uses `ref` for lazy `Page.raw`/`document` accessors and selected
  `return ref`/`inout return` APIs to express reference lifetime and
  qualification. These are unannotated accessors and may perform lazy
  fetching/parsing; field-like syntax alone does not promise a pure read
  ([`Page`](../../Libraries/akashi/source/akashi/page.d#L55-L92),
  [`Node`/`Document`](../../Libraries/akashi/source/akashi/text/ast.d#L76-L112)).
- **Insurgent Client** uses `private:` / `public:` sections and ordinary
  accessor-like methods. Its own `Ledger.depth()` / `currentPage()` are read
  without parentheses at a call site, while Selenium's `driver.url()` is
  called with parentheses in the same client. This mixed use argues for clear
  local API contracts rather than a global punctuation ban
  ([`Ledger`](../../Insurgent/client/source/render/kit/ledger.d#L104-L118),
  [catalog call site](../../Insurgent/client/source/gui/catalog/view.d#L85-L96),
  [game call site](../../Insurgent/client/source/gui/game.d#L192-L195)).
- **Insurgent API** has no D source files in the checked-out repository. Its
  README describes intended modules, but those docs cannot establish actual
  source conventions; do not infer its implementation style from planned
  imports ([`README.md`](../../Insurgent/api/README.md#L70-L87),
  [`dub.json`](../../Insurgent/api/dub.json#L1-L11)).

For broader examples of module layout, naming, comments, error handling,
TypeScript, and test organization, see
[`reference-style.md`](reference-style.md). It records repository snapshots
and source paths.

### Attributes and Qualifiers

Attributes and qualifiers change compiler checks, API registration, or runtime
behavior. They are semantic contracts, not decorative annotations.

| Form | Meaning and style |
| --- | --- |
| `@property` | Marks an accessor function for property-style use. See the preceding section. |
| `@safe`, `@trusted`, `@system` | D memory-safety contracts. Use a safe surface where the implementation and dependencies support it; isolate and audit unsafe operations behind a small `@trusted` boundary. Do not label a function `@trusted` merely to silence a compiler diagnostic. `@system` is not a substitute for checking a safety boundary. |
| `@nogc` | Promise that the annotated function/path does not allocate through the GC. Add it only when it is a deliberate API/performance requirement and the compiler can verify the complete call path. It appears in Selenium and Akashi, but is not a universal annotation. |
| `pure`, `nothrow` | Effect/error contracts. Keep them when they describe a true contract; do not add them as boilerplate or infer they are implied by the function's name. |
| `@disable` | Disables a particular operation, commonly a constructor or copy operation. Use it to prevent a real invalid/unsafe operation, not as a generic class decoration. |
| `override` | Marks an overriding virtual/interface member so an accidental signature mismatch is a compiler error. Keep it on actual overrides; it is not a naming convention. |
| `deprecated("reason")` | Marks a compatibility path as deprecated and can tell callers what replaces it. Use when an API is intentionally retained during migration, not as a substitute for an ordinary comment. |
| `extern(C)` | Declares the foreign ABI/linkage contract. Keep it at the declaration boundary that interoperates with C; it is unrelated to `public` or `package` visibility. |
| `version (Name)` | Selects compile-time platform or feature branches. Keep platform-specific declarations in the relevant version block rather than copying a whole API with runtime conditionals. |
| User-defined attributes, for example `@endpoint`, `@route`, `@priority`, `@Name`, and `@Serial` | Framework/test metadata consumed by Serverino or the test runner. Preserve the names, template arguments, and association with the declaration; they are executable registration/runner behavior, not visual style. |
| `ref`, `out`, `in`, `inout`, `const`, `immutable`, and `shared` | Parameter-passing or type-qualification contracts. `ref` exposes/uses an alias; `inout` preserves the caller's mutability qualification across an API. Do not add them as decoration. |
| `scope`, `return`, `static`, and `lazy` | Storage, lifetime/escape, or evaluation contracts. In particular, `scope` and `return` on reference- or slice-bearing APIs participate in lifetime safety; use them only when the intended lifetime is clear and compiler-checked. They are not visibility labels. |
| `__gshared` | Makes module-level storage process-global instead of thread-local; it does not make mutable state thread-safe. Use only when process-global storage is intentional and synchronize mutable access. It is present in Akashi's configuration declaration. |

An attribute block such as `@safe:` or a visibility section such as `private:`
affects subsequent declarations in its lexical scope. A single declaration
can also carry attributes directly. Keep an attribute close to the
declaration it governs unless a block accurately captures the whole group.
Property getter and setter overloads, template declarations, and protocol
handlers are distinct declarations: do not assume a semantic attribute or UDA
on one automatically applies to its siblings.

Autonom's `@endpoint`, `@route`, `@priority`, and lifecycle UDAs in
[`server.d`](../source/daemon/server.d#L22-L136) and its tests' `@Name` and
`@Serial` attributes are framework contracts. Selenium's
[`@nogc` bridge functions](../../Libraries/selenium/source/selenium/bridge.d#L77-L82)
are examples of an effect promise. Akashi combines `pure`, `nothrow`, and
`@nogc` on small parser/AST accessors
([`ast.d`](../../Libraries/akashi/source/akashi/text/ast.d#L84-L112)).
Its module-level `__gshared` configuration
([`page.d`](../../Libraries/akashi/source/akashi/page.d#L11-L17)) is an
intentional process-global state choice, not a recommendation to use shared
mutable globals by default.
Autonom does not establish `@safe`, `@trusted`, `pure`, `nothrow`, or `@nogc`
as a blanket house style; introduce such an attribute for a verified semantic
requirement.

### Functions, Templates, and Returns

- Use `static` when a function is not tied to an instance. Use an ordinary
  instance method when it acts on owned object state.
- Use a template constraint to express the actual type requirements of a
  generic operation. Keep template helpers lower camel case and data/type
  templates PascalCase; use conventional capital template parameters for type
  variables. Do not add template machinery for a single concrete case.
- Prefer overloads when they form one coherent operation (such as a property
  getter/setter or typed `config` lookup); use distinct names when behaviors
  differ enough that overload resolution would surprise callers.
- A direct `return expression;` is good when it is clear. Use a named `ret`
  when it accumulates or constructs a result across multiple steps. Do not
  create a temporary solely to satisfy a naming rule.
- Keep a function's `ref`, `const`, `inout`, `scope`, `nothrow`, safety, or
  allocation contract only where intended and correct. These modifiers affect
  how callers may use the function.

### Layout and Documentation

- Use four-space indentation and Allman braces in D source.
- A one-statement, non-nested branch may omit braces when it stays
  unambiguous. Use braces for multiple statements, nested flow, cleanup, and
  rollback. Add braces as soon as a branch grows.
- Separate declarations and logical blocks with blank lines. Wrap long
  parameter lists, chained calls, and literals when it improves scanning;
  four-or-more-item lists are a useful cue to consider one item per line, not
  a mandatory split for every compact initializer or call.
  treat roughly 120 columns as a useful target, not a reason to split a simple
  expression into noise.
- Avoid trailing whitespace and alignment padding.
- Document public/library APIs with Ddoc when callers need parameter,
  failure, lifetime, or protocol details. In application code, keep internal
  comments concise and attach them to the relevant invariant.
- Do not use comment rulers or boilerplate section headers inside source
  modules. Use a new file/package only when it reflects an actual domain or
  ownership boundary.

## TypeScript

- Use four-space indentation, Allman braces, double-quoted strings/imports,
  `camelCase` for functions and values, and `PascalCase` for types.
- End statements with semicolons; do not rely on automatic semicolon
  insertion.
- Use `const` unless the binding is reassigned. Keep an explicit type at a
  stable module/API boundary when it documents the contract; local inference
  is normal TypeScript and should not be banned.
- Use `unknown` for untrusted/external data and narrow it before use. Isolate
  `any` to genuinely dynamic host/vendor interfaces where the runtime shape
  cannot be expressed conveniently; do not spread it across ordinary logic.
- Use `node:` prefixes for Node built-in imports and keep imports at module
  scope unless a dynamic import is part of the behavior.
- Use `ret` for an explicit constructed/accumulated result when that matches
  the surrounding code. Direct returns do not need a named local.
- Keep launcher/browser-runtime code separate where the runtime environment or
  authority genuinely differs. Do not split simple direct code into extra
  adapters or mirror directories just to satisfy a fixed file-count rule.
- Use the existing `node:test` and `node:assert/strict` conventions for
  launcher unit tests. Test actual interactions at the appropriate layer;
  synthetic host-service fixtures are not evidence of live Desktop behavior.

## Python

- Use four-space indentation, `snake_case` functions and values,
  `PascalCase` types, and uppercase module constants.
- Prefer the standard library and explicit data/HTTP boundaries, matching the
  small hook and MCP entrypoints in this repository.
- Keep subprocess output, credentials, environment forwarding, and exception
  behavior bounded and intentional. Security-sensitive hooks fail closed when
  required authentication or validation fails.
- Follow the repo's chosen test runner (`unittest` here); do not impose D or
  TypeScript naming/accessor rules on Python.

## Test and File Organization

- Keep tests near the conventions of the language and existing suite:
  descriptive D `@Name` tests with the repository's unit runner, TypeScript
  `node:test` under `tests/unit/`, and Python `unittest` where used.
- Share a fixture when it represents a real repeated boundary. Avoid a generic
  test framework or broad mock layer for a handful of local tests.
- Group files by domain and ownership. A `package.d` re-export is useful when
  it gives callers a stable public package surface; it is not mandatory.
  Avoid tiny one-symbol modules whose only effect is another import hop.
- Use a consistent, descriptive filename in the surrounding repository. Do
  not reject an underscore or force a rename without a real import/API reason.
- Keep generated/build output out of source control according to the
  repository's existing build layout.

## Evidence Snapshots

The D examples above were checked in these local repository revisions. The
Insurgent API entry is included because it was requested, even though its
current checkout contains no D source.

| Repository | Revision |
| --- | --- |
| Autonom | `08a8af4bb4321021c3f4ef4f167ea14d55c23dc1` |
| Intuit | `86248d51345ada6a06c254163e1bedb12acf29ad` |
| Selenium | `0eabfd8f41df1c982a65f42db4f106c1bfa313a3` |
| Webull SDK | `ab2f1622c219f8745c6bfbf2023831ed7378be67` |
| Akashi | `63c514f4ac031b98de857e07ede755d517723afb` |
| Insurgent API | `7f66a8e982ea1f1fdab5083c1e707da618c4a74d` |
| Insurgent Client | `3694362d5e6b4780a6339adfd031778e3ed4da1f` |

## Replacing Old Absolutes

The following are not universal rules:

- "Never use `@property`." Use it for intentional field-like accessors; use a
  method for actions. Both annotated and unannotated property-like accessors
  exist in the reference code.
- "Property-style accessors must be lambda functions and UFCS." Named methods,
  overloads, `@property`, and UFCS are all valid tools; choose the clearest
  shape.
- "All returns must be named `ret`." Use `ret` for a meaningful accumulator;
  return a direct expression otherwise.
- "Ban `auto`." D and TypeScript inference are normal; choose explicit types
  where they communicate the contract.
- "Remove every single-use temporary." Keep temporaries that clarify lifetime,
  validation, ownership, sequencing, locking, or error handling.
- "All imports must be selective and top-level." Top-level, grouped imports are
  the default; local or broad imports can be appropriate for a genuinely
  limited/test-only dependency or a cohesive module.
- "Every source file must use a rigid line/item count, visibility order, or
  naming exception list." Optimize for readability and established local
  semantics instead of checklist compliance.
- "No comments except protocol notes." Use focused comments and Ddoc where
  they preserve useful invariants, public contracts, or non-obvious behavior.
