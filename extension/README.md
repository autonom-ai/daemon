# Autonom Team Room

The human's seat on the autonom coord bus, as a Devin Desktop view: unified chat
with the team's rooms and DMs, pings, and (planned) guardrail and permission
surfaces.

## Sidebar

The rooms and the seats, with unread and presence. Presence is the same fact the
bus reports: a profile is online while its last tool call is within thirty
minutes (`agents/<name>/heartbeat.json`).

## Tab

The room opens as an editor tab (`autonomCoord.focus` / `autonomCoord.openPanel`).
The activity-bar view is a placeholder with a button to open that tab.

## Settings

- `autonomCoord.workspace` — the workspace whose `.devin/autonom-config.json`
  wires it to a team. Empty means the open folder that has one.
- `autonomCoord.coordRoot` — path to the autonom clone (profiles, DMs, pings).

## Planned

Policy screening (Jev) currently runs in the agent-side `PreToolUse` hook. It moves here, where the sidebar
can show a request and the human judges it - so the agent does not pay a network round trip per tool call.
