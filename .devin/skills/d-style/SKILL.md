---
name: d-style
description: Enforce Autonom D, TypeScript, and Python conventions, Intuit/Selenium ownership patterns, and architectural layer boundaries
argument-hint: "[path or module]"
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Autonom Code Style & Architecture Conventions

This skill enforces the working style guide ([docs/DEVELOPMENT.md](../../../docs/DEVELOPMENT.md)), the architectural idioms from `/home/cet/Repos/Libraries/intuit` and `/home/cet/Repos/Libraries/selenium`, and the strict `Interop + DB -> Daemon -> ACP` layer boundaries.

Run the automated checker before committing or completing any phase:

```bash
python3 .devin/skills/d-style/tools/check-style.py
```

---

## 1. Architectural Ownership & Layer Boundaries

Autonom is structured in three strict layers (`Interop + DB -> Daemon -> ACP`):

| Layer | Package | Allowed Imports & Ownership | Forbidden |
|---|---|---|---|
| **1A. Database** | `daemon.db` | Owns `<dataDir>/autonom.db` (`arsd.sqlite`), schema, transactions, and `client.token` / MCP token auth | Must not import `daemon.agent`, `daemon.coord`, `daemon.events`, `daemon.acp`, or `serverino` |
| **1B. Interop** | `daemon.interop` | Thin `intuit`-style interactive provider wrapper (`IProvider`, `ISession`, `ProviderRegistry`, `AcpStream`, `DevinProvider`, `DevinSession`, `hooks`, `mcp`) | Must **never** import `daemon.coord`, `daemon.events`, `daemon.policy`, or `daemon.acp` (except `mcp.d` if it hosts a route, or keep routes in `daemon.api`). The session routes read the profile type from `daemon.agent`. No `Call` or `Execution` classes. |
| **2. Daemon Domain** | `daemon.agent`, `daemon.coord`, `daemon.events`, `daemon.policy`, `daemon.hooks`, `daemon.api` | Backed directly by `daemon.db` and `daemon.interop` (`ProviderRegistry` / `ISession`) | No JSON/JSONL file streams (`Stream`), no reverse control sockets (`<connection>.sock`), no loopback HTTP pokes |
| **3. Autonom ACP** | `daemon.acp` | Hosted in-process on `<dataDir>/acp/daemon.sock` atop `daemon.agent` (`ProfileStore`) and `daemon.coord` (`Bus`); the `autonom acp` command is a thin stdio ↔ socket relay | Must never spawn `devin acp` directly or poll the daemon over HTTP |

### Reference Library Idioms (`Intuit` & `Selenium`)

- **Interfaces only for real provider seams (`Intuit`)**:
  - `IProvider` and `ISession` in `daemon.interop.provider` mirror `intuit.provider.IEndpoint` and `intuit.router.IRouter`: small, direct methods (`id()`, `name()`, `createSession()`, `loadSession()`, `prompt()`, `steer()`, `cancel()`, `setModel()`, `setMode()`, `setTitle()`), `ref` accessors only where caller mutation of owned config is intended (`ref SessionConfig config()`), and `ProviderRegistry` for multi-provider lookup.
- **Concrete handles (`Selenium`)**:
  - Domain objects (`Profile`, `Room`, `AcpStream`, `Database`) are concrete classes. Do not create `Base` / `Impl` class pairs (`SessionBase` / `Session`) or speculative interfaces with one implementation.
- **File size targets**:
  - Aim for ~200 lines per file; **stay under 400 lines**. Split distinct responsibilities before a file approaches 400 lines.

---

## 2. D Language Conventions

### Naming & Casing

- **Types (`class`, `struct`, `interface`, `enum`, `Exception`)**: `PascalCase`.
- **Functions, methods, fields, parameters, locals, constants**: `camelCase`.
- **Enum members**: `PascalCase`, even when wire values are lowercase/snake_case:
  ```d
  enum TurnStatus : string
  {
      Idle = "idle",
      Running = "running",
      Waiting = "waiting",
      Unknown = "unknown"
  }
  ```
- **Constants**: `enum frameLimit = 16 * 1024 * 1024;` — **never** `UPPER_SNAKE_CASE` (except external C/SQLite symbols like `SQLITE_OPEN_READWRITE` or `LOCK_EX`).
- **Constructed return value**: Always name an accumulated return variable `ret`. Return a single expression directly without a temporary.
- **Module names**: lowercase without underscores (`package.d`, `stream.d`, `provider.d`).

### Types & Inference

- **Explicit local types**: Write `Profile profile = store.get(name);` or `Session* found = id in sessions;`. Do **not** use `auto` for routine nameable types.
- **`struct` vs `class`**: Use `struct` for value records, options, and results (`Frame`, `SessionConfig`, `PromptResult`, `Permission`, `Event`, `Schedule`). Use `class` for identity-bearing services and shared mutable owners (`Database`, `AcpStream`, `DevinProvider`, `DevinSession`, `Profile`, `ProfileStore`, `Room`, `Bus`).

### Module Layout & Imports

1. `module ...;` declaration first.
2. **Three import groups** separated by one blank line:
   - Project imports (`daemon.*`, `tests.*`)
   - External dependency imports (`arsd.sqlite`, `intuit.*`, `mir.*`, `serverino`, `unit_threaded`)
   - Runtime/standard library imports (`core.*` before `std.*`)
3. Keep imports at module scope (never inside ordinary functions).
4. Group class members by access section (`private:`, `package(...):`, `protected:`, `public:`) rather than switching repeatedly. Put fields before constructors, and constructors before methods.

### Braces, Expressions & Whitespace

- **4-space indentation, Allman braces**.
- **Single-line bodies**: Omit braces when a scoped control statement (`if`, `else`, `foreach`, `while`) has one non-nested statement on one physical line. If any branch or outer block uses braces, keep braces on the enclosing block.
- **Empty blocks**: Write `{ }` on one line.
- **Short methods**: Use `=> expr;` only when the entire expression fits on one physical line.
- **Delegate literals**: Put `{` on the same line as the delegate introducer:
  ```d
  database.transaction({
      database.exec("DELETE FROM autonom_events WHERE profile = ?", name);
  });
  ```
- **String concatenation & slices**: No spaces around `~`, `..`, `cast(Type)val`, or `$-1`:
  ```d
  string path = directory~"/"~items[0..$-1];
  ```
- **Loops**: No `while (true)` or `for (;;)` sentinel loops; use a meaningful loop predicate.
- **Scope guards**: Write `scope(exit)` and `scope(failure)` with no space before `(`.

---

## 3. TypeScript & Python Conventions

- **TypeScript (the launcher in [autonom-ai/devin](https://github.com/autonom-ai/devin))**: 4-space indentation, Allman braces, double-quoted strings, semicolons, `camelCase` values/functions, `PascalCase` types, `unknown` narrowed at boundaries.
- **Python (`source/mcp/`, `templates/hook.py`, `install.py`, `tests/install.py`)**: 4-space indentation, `snake_case` functions/variables, `PascalCase` classes, `UPPER_SNAKE_CASE` module constants, standard library only.
