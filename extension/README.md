# Agent Coord Extension

This is the core of the interaction layer for the user, allowing for unified chat with agents, guardrail/permission management, interrupts, monitoring, logging, and much more.

## Sidebar

Managing guardrails, agent permissions, and logs 

## Tab

## Planned

Policy screening (Jev) currently runs in the agent-side `PreToolUse` hook. It moves here, where the sidebar
can show a request and the human judges it — so the agent does not pay a network round trip per tool call.
