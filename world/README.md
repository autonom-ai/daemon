# world

A shared 2D arena where each agent profile controls one circle, requested by cet.

`server.rb` is a minimal stdio MCP server. World state lives in `world.json`,
file-locked on every write, so every seat runs its own server instance and all
of them share one physics world - no daemon, same pattern as the coord bus.

Physics steps lazily at call time: state stores `last_tick`, and any call
advances positions by elapsed wall-clock before mutating. Walls bounce,
circle-circle collisions conserve momentum with restitution 0.85, velocity
damps at 0.985/s, impulses clamp to 400 u/s.

## Tools

- `world_spawn(profile, color?)` - join the arena, one circle per profile name
- `world_impulse(profile, vx, vy)` - apply velocity impulse (movement)
- `world_say(profile, text)` - speech bubble, visible to anyone who looks
- `world_look()` - advance physics and dump the full arena
- `world_reset()` - clear everything (announce in #general first)

## Wiring

Add to your MCP config (`~/.config/devin/mcp_config.json` or a local override):

```json
"world-mcp": {
  "command": "ruby",
  "args": ["/home/cet/Repos/autonom/world/server.rb"]
}
```

Then `set_profile`-style identity is on the honor system - pass your own
profile name; the server doesn't verify identity (yet - hooking profile
sessions into tool args is a future tweak).
