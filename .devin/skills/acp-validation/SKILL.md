---
name: acp-validation
description: Validate Autonom ACP wire frames against the installed Devin Desktop Zod validator/reducer and benchmark SQLite autonom.db query plans and CLI coexistence
argument-hint: "[wire|sql|all]"
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Autonom ACP Wire & SQLite Validation

This skill prevents the two classes of defects that broke earlier conversation implementations:

1. **Invalid ACP wire frames** that pass synthetic D string checks or direct reducer unit tests while being rejected at runtime by Devin Desktop's installed `@exa/windsurf-acp` Zod validator (`createAcpIncomingMessageValidator`).
2. **Unbounded or unindexed SQLite queries** (recursive CTEs or window sorts without pushdown bounds) and schema collisions between Autonom's `autonom_*` tables and Devin CLI's `sessions`/`message_nodes` tables in `<dataDir>/autonom.db`.

---

## 1. ACP Wire Ingress & Reducer Validator (`tools/validate-acp.mjs`)

Run the installed-bundle wire validator directly in Node (no Electron window required):

```bash
node .devin/skills/acp-validation/tools/validate-acp.mjs
```

You can also pipe a JSONL file or stream of JSON-RPC frames emitted by `autonom-daemon` / `autonom-acp` into it:

```bash
node .devin/skills/acp-validation/tools/validate-acp.mjs --file /path/to/frames.jsonl
```

### Verified Protocol v1 Rules

- **Negotiated protocol**: Autonom's ACP host negotiates `protocolVersion: 1`.
- **User messages**:
  - Must use `sessionUpdate: "user_message_chunk"` with object `content: {"type": "text", "text": "..."}` and `_meta: {"cognition.ai/clientMessageId": "<id>", "cognition.ai/messageSubIndex": 0}`.
  - Whole `user_message` is a v2-only schema and is **rejected** by the v1 validator.
- **Assistant & thought chunks**:
  - Use `sessionUpdate: "agent_message_chunk"` and `"agent_thought_chunk"` with object `content: {"type": "text", "text": "..."}`.
- **Tool calls & updates**:
  - `sessionUpdate: "tool_call"` requires `toolCallId`, `title`, and optional `kind`, `status`, `rawInput`, `content`, `_meta`.
  - `sessionUpdate: "tool_call_update"` requires `toolCallId` and optional `status`, `content`, `rawOutput`, `_meta`.
- **Session titles**:
  - Use `sessionUpdate: "session_info_update"` with `title: "<name>"`.

---

## 2. SQLite Coexistence & Query Plan Validator (`tools/check-sql.py`)

Run the SQLite schema, query plan (`EXPLAIN QUERY PLAN`), and 10,000-row performance validator:

```bash
python3 .devin/skills/acp-validation/tools/check-sql.py
```

### What It Verifies

1. **Coexistence in `<dataDir>/autonom.db`**:
   - Creates both Devin CLI's tables (`sessions`, `message_nodes`, `tool_call_state`, `prompt_history`, `rendered_commits`, `subagent_heads`, `app_state`, `refinery_schema_history`) and Autonom's `autonom_*` tables in one WAL database.
   - Verifies zero table/index name collisions and foreign-key integrity.
2. **Query Plan Checks (`EXPLAIN QUERY PLAN`)**:
   - Verifies that room message reads, profile aggregated message reads (`autonom_profile_messages`), DM/ping reads, event reads, and schedule due checks use covering indexes (`SEARCH ... USING INDEX`) with **zero** full table scans (`SCAN`) and **zero** temporary B-tree sorts (`USE TEMP B-TREE`).
3. **10,000-Message Performance Budget**:
   - Seeds 10,000 room messages and 10,000 profile messages across multiple linked sessions.
   - Asserts that a 64-row page read completes in **< 2 ms** (cold or warm) and incremental delta sync (`node_id > last_synced`) runs in O(new nodes), never rescanning historical chains.
