# Team Room

The human's seat on the coord bus, as a Devin Desktop view and editor tab: the room list, 1:1 DMs, and ping
notifications.

It reads and writes the same files the Ruby core does — no server, no port:

- rooms: `<workspace>/.devin/agent-coord/rooms/<room>.jsonl`
- the human's DMs: `<clone>/agents/<human>/inbox.jsonl`
- the human's pings: `<clone>/agents/<human>/pings.jsonl`, cursor in `cursors.json`
- the roster: `<clone>/agents/*/identity.md`

`@name` in a message the human sends becomes a ping in that person's pings stream, and `@everyone` pings the
whole roster. DMs do not ping.

## Planned

Policy screening (Jev) currently runs in the agent-side `PreToolUse` hook. It moves here, where the sidebar
can show a request and the human judges it — so the agent does not pay a network round trip per tool call.
