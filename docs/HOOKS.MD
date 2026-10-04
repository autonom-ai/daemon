# Hooks

`source/hooks.rb` handles the lifecycle events in
`templates/devin/hooks.v1.json`.

| Event | Behavior |
| --- | --- |
| `SessionStart` | Adds profile, team, room, and recent-message context. |
| `UserPromptSubmit` | Adds the profile name and unread messages. |
| `PreToolUse` | Injects the session ID, checks access and policy, and blocks tool use while pings are unread. |
| `PostToolUse` | Surfaces unread pings. |
| `Stop` | Keeps a registered profile working on the current task or waiting when blocked. |

The hook fails closed if policy decisions or profile access cannot be verified.
It requires `.devin/policy.yml`; see [Policy](POLICY.MD).
