#!/usr/bin/env python3
"""Validates Autonom + Devin CLI SQLite schema coexistence, query plans, and 10k-row latency."""

import sqlite3
import sys
import time

CLI_DDL = """
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    working_directory TEXT NOT NULL,
    backend_type TEXT NOT NULL,
    model TEXT NOT NULL,
    agent_mode TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    last_activity_at INTEGER NOT NULL,
    title TEXT,
    main_chain_id INTEGER,
    shell_last_seen_index INTEGER DEFAULT 0,
    cogs_json TEXT,
    workspace_dirs TEXT,
    hidden INTEGER NOT NULL DEFAULT 0,
    metadata TEXT
);

CREATE TABLE IF NOT EXISTS message_nodes (
    row_id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    node_id INTEGER NOT NULL,
    parent_node_id INTEGER,
    chat_message TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    metadata TEXT,
    FOREIGN KEY (session_id) REFERENCES sessions(id),
    UNIQUE(session_id, node_id)
);

CREATE TABLE IF NOT EXISTS tool_call_state (
    session_id TEXT NOT NULL,
    tool_call_id TEXT NOT NULL,
    tool_call_json TEXT,
    tool_call_update_json TEXT,
    PRIMARY KEY (session_id, tool_call_id),
    FOREIGN KEY (session_id) REFERENCES sessions(id)
);
"""

AUTONOM_DDL = """
CREATE TABLE IF NOT EXISTS autonom_schema (
    version INTEGER PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS autonom_profiles (
    name TEXT PRIMARY KEY,
    current_session TEXT,
    provider TEXT NOT NULL DEFAULT 'devin',
    workspace TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    mode TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'offline',
    activity TEXT NOT NULL DEFAULT 'idle',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS autonom_sessions (
    id TEXT PRIMARY KEY,
    provider TEXT NOT NULL DEFAULT 'devin',
    profile TEXT NOT NULL REFERENCES autonom_profiles(name) ON DELETE CASCADE,
    workspace TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT '',
    mode TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    base_title TEXT NOT NULL DEFAULT '',
    config_options TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'offline',
    activity TEXT NOT NULL DEFAULT 'idle',
    trusted INTEGER NOT NULL DEFAULT 0,
    mcp_token TEXT UNIQUE,
    removed INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    last_activity_at INTEGER NOT NULL
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_autonom_sessions_profile
    ON autonom_sessions(profile, created_at);

CREATE TABLE IF NOT EXISTS autonom_profile_sessions (
    profile TEXT NOT NULL REFERENCES autonom_profiles(name) ON DELETE CASCADE,
    session TEXT NOT NULL REFERENCES autonom_sessions(id) ON DELETE CASCADE,
    linked_at INTEGER NOT NULL,
    unlinked_at INTEGER,
    PRIMARY KEY (profile, session)
) WITHOUT ROWID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_autonom_profile_sessions_active
    ON autonom_profile_sessions(session)
    WHERE unlinked_at IS NULL;

CREATE TABLE IF NOT EXISTS autonom_profile_messages (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT NOT NULL UNIQUE,
    profile TEXT NOT NULL REFERENCES autonom_profiles(name) ON DELETE CASCADE,
    session TEXT NOT NULL REFERENCES autonom_sessions(id) ON DELETE CASCADE,
    node_id INTEGER NOT NULL DEFAULT 0,
    role TEXT NOT NULL,
    content TEXT NOT NULL DEFAULT '',
    thinking TEXT,
    tool_calls TEXT,
    tool_call_id TEXT,
    tool_state TEXT,
    client_message_id TEXT,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_autonom_profile_messages_profile_seq
    ON autonom_profile_messages(profile, seq);

CREATE TABLE IF NOT EXISTS autonom_rooms (
    name TEXT PRIMARY KEY,
    owner TEXT NOT NULL REFERENCES autonom_profiles(name),
    restricted INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS autonom_messages (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL,
    room TEXT REFERENCES autonom_rooms(name) ON DELETE CASCADE,
    sender TEXT NOT NULL REFERENCES autonom_profiles(name),
    recipient TEXT REFERENCES autonom_profiles(name),
    text TEXT NOT NULL,
    client_message_id TEXT,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_autonom_messages_room_seq
    ON autonom_messages(room, seq) WHERE kind = 'room';
CREATE INDEX IF NOT EXISTS idx_autonom_messages_recipient_seq
    ON autonom_messages(kind, recipient, seq);
"""


def assert_indexed_plan(conn: sqlite3.Connection, label: str, sql: str, params: tuple) -> None:
    plan_rows = conn.execute("EXPLAIN QUERY PLAN " + sql, params).fetchall()
    details = " | ".join(row[3] for row in plan_rows)
    if "SCAN" in details or "TEMP B-TREE" in details:
        raise AssertionError(f"{label} uses non-indexed scan or temp sort: {details}")
    print(f"PASS plan [{label}]: {details}")


def main() -> int:
    conn = sqlite3.connect(":memory:")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(CLI_DDL)
    conn.executescript(AUTONOM_DDL)

    conn.execute("INSERT INTO autonom_profiles(name, created_at, updated_at) VALUES ('human', 0, 0)")
    conn.execute("INSERT INTO autonom_profiles(name, created_at, updated_at) VALUES ('marlow', 1, 1)")
    conn.execute(
        "INSERT INTO autonom_sessions(id, profile, workspace, created_at, last_activity_at) "
        "VALUES ('s-1', 'marlow', '/tmp', 1, 1)"
    )
    conn.execute("INSERT INTO autonom_rooms(name, owner, created_at, updated_at) VALUES ('general', 'marlow', 1, 1)")

    assert_indexed_plan(
        conn,
        "profile_messages_page",
        "SELECT seq, id, role, content FROM autonom_profile_messages WHERE profile = ? AND seq > ? ORDER BY seq LIMIT ?",
        ("marlow", 0, 64),
    )
    assert_indexed_plan(
        conn,
        "room_messages_page",
        "SELECT seq, id, sender, text FROM autonom_messages WHERE kind = 'room' AND room = ? AND seq > ? ORDER BY seq LIMIT ?",
        ("general", 0, 64),
    )
    assert_indexed_plan(
        conn,
        "dm_messages_page",
        "SELECT seq, id, sender, text FROM autonom_messages WHERE kind = ? AND recipient = ? AND seq > ? ORDER BY seq LIMIT ?",
        ("dm", "marlow", 0, 64),
    )

    with conn:
        conn.executemany(
            "INSERT INTO autonom_profile_messages(id, profile, session, node_id, role, content, created_at) "
            "VALUES (?, 'marlow', 's-1', ?, 'assistant', ?, ?)",
            [(f"s-1:{i}", i, f"message-{i}", i) for i in range(1, 10001)],
        )
        conn.executemany(
            "INSERT INTO autonom_messages(id, kind, room, sender, text, created_at) "
            "VALUES (?, 'room', 'general', 'marlow', ?, ?)",
            [(f"r-{i}", f"room-message-{i}", i) for i in range(1, 10001)],
        )

    t0 = time.perf_counter()
    rows = conn.execute(
        "SELECT seq, id, role, content FROM autonom_profile_messages WHERE profile = ? AND seq > ? ORDER BY seq LIMIT ?",
        ("marlow", 9900, 64),
    ).fetchall()
    dt_ms = (time.perf_counter() - t0) * 1000.0
    if len(rows) != 64 or dt_ms > 5.0:
        raise AssertionError(f"Profile page failed budget: {len(rows)} rows in {dt_ms:.3f} ms")
    print(f"PASS 10k profile transcript page: {len(rows)} rows in {dt_ms:.3f} ms")

    t0 = time.perf_counter()
    rows = conn.execute(
        "SELECT seq, id, sender, text FROM autonom_messages WHERE kind = 'room' AND room = ? AND seq > ? ORDER BY seq LIMIT ?",
        ("general", 9900, 64),
    ).fetchall()
    dt_ms = (time.perf_counter() - t0) * 1000.0
    if len(rows) != 64 or dt_ms > 5.0:
        raise AssertionError(f"Room page failed budget: {len(rows)} rows in {dt_ms:.3f} ms")
    print(f"PASS 10k room message page: {len(rows)} rows in {dt_ms:.3f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
