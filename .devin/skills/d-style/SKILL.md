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

This skill enforces the shared conventions ([core/docs/CONVENTIONS.md](../../../core/docs/CONVENTIONS.md)), the architectural idioms from the Intuit and Selenium reference repositories, and the strict `Interop + DB -> Daemon -> ACP` layer boundaries.

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

## 2. Shared Language Conventions

The D, TypeScript, and Python conventions are canonical in
[core/docs/CONVENTIONS.md](../../../core/docs/CONVENTIONS.md). Read that guide
before writing or reviewing code. It covers naming, types and inference, module
layout, imports, braces, whitespace, accessors, comments, errors, and tests.

This skill keeps only the repository-specific layer boundaries above and the
checker below. Do not duplicate the shared rules here.
