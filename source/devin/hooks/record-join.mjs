// PostToolUse — the only place a tab's identity gets recorded.
//
// A join on `agent-coord-<name>` is the identity act: the entry is pre-bound
// to that name (AGENT_COORD_BOUND_AGENT) and the bus refuses any other, so a
// successful join through that entry proves this tab is <name>. The hook sees
// the three facts together and nowhere else — the tool name (which entry the
// tab itself chose), the response (the bus accepted it), and the session id
// (which tab). Process ancestry could not: the client root is shared across
// tabs, so it matched every tab's servers and froze a stranger's name into the
// claim file.
//
// A refused join records nothing — a claim is evidence, not intent.

import { claimFor, hookInput, recordClaim } from "./coord.mjs";

const input = await hookInput();
const match = /^mcp__agent-coord-([A-Za-z0-9_-]+)__(join|register)$/.exec(input.tool_name ?? "");
if (!match || !input.session_id)
    process.exit(0);
const entry = match[1];
// The entry name is the identity. An agentId that disagrees with it is a call
// the bus refuses, and a claim for it would be a guess.
const agentId = input.tool_input?.agentId;
if (agentId && agentId !== entry)
    process.exit(0);
// Explicit failure — a live incumbent, a name mismatch — records nothing.
// Refusals are thrown errors, so they arrive as success: false.
if (input.tool_response?.success !== true)
    process.exit(0);
if (claimFor(input.session_id) !== entry)
    recordClaim(input.session_id, entry);
