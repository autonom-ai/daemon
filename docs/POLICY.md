# Policy and hooks

Policy decides whether a tool call runs. It is enforced by the daemon, evaluated for every call — including automatic and bypassed ones — and applied before the tool executes. Hooks are how the daemon learns about those calls at all.

Two pieces:

| Piece | What it is |
| --- | --- |
| **Workspace policy** | `.devin/policy.yml` in the session's workspace: ordered rules that allow, deny, or screen a tool call. |
| **Devin CLI hooks** | Global lifecycle callbacks the daemon installs, so `PreToolUse` reaches the policy engine and events reach coordination. |

## The policy file

```yaml
rules:
  - action: deny
    match:
      command: 'rm\s+-rf\s+/'
    reason: Refusing to delete the filesystem root
```

| Field | Required | Meaning |
| --- | --- | --- |
| `action` | Yes | `allow`, `deny`, or `screen`. |
| `match` | No | Field patterns. `tool` matches the tool name; any other key matches that string field of the tool input. Values are regular expressions. A rule with no `match` matches every call. |
| `reason` | No | Text returned to the model when the call is denied. Defaults to `Denied by workspace policy`. |
| `models` | Screen only | Screening models tried in order. |
| `questions` | Screen only | Predicate questions asked of the screening model. |
| `threshold` | No | Probability at or above which a screening answer counts as harmful. Default `0.5`. |

Unknown fields, duplicate keys, malformed YAML, or a screen rule without models or questions fail closed — the request is denied with the parse error.

## Evaluation

Rules run in order and the first match decides:

| Action | Result |
| --- | --- |
| `allow` | The call is not blocked, and evaluation stops. |
| `deny` | The call is blocked with the rule's reason. |
| `screen` | Each model is asked the rule's questions. Any predicate answer at or above `threshold` blocks the call; otherwise it proceeds. |

Screening shares one 8-second budget across the models in a rule and fails the request if the budget is exhausted. Only screening uses a model; the rest of the policy engine is local.

Screening models are reached through the `router` block in the daemon configuration. It is required, and its key is the only credential the daemon holds for this purpose:

```yaml
router:
  type: openrouter
  key: ""
  url: https://openrouter.ai
  name: OpenRouter
```

`templates/policy.yml` ships a screening example.

## Hook installation

The CLI loads hooks from the user-level Devin configuration. On daemon startup and on every session admission, the daemon renders `devin/hooks.v1.json` — replacing `{{AUTONOM_ROOT}}` with the installed payload root — and merges the result under `hooks` in `~/.config/devin/config.json`.

| Property | Behavior |
| --- | --- |
| Scope | One registration covers every managed session, regardless of workspace. |
| Merge | Unrelated settings and user-owned hook commands are preserved, including commands that share a matcher with Autonom. |
| Repair | Entries pointing at a moved or deleted `hook.py` are replaced rather than left to fail closed. |
| Project hooks | A workspace's own `.devin/hooks.v1.json` continues to load separately. |
| Failure | A malformed user configuration is refused without being replaced. |

## Hook events

| Event | Effect |
| --- | --- |
| `PreToolUse` | Evaluates policy, adopts pending wakes, and injects the session ID into coordination tool inputs. |
| `PostToolUse` | Returns a reminder when the profile has unread events (up to five summaries). |
| `UserPromptSubmit` | Same reminder as `PostToolUse`. |
| `PermissionRequest` | Returns an empty response. Approval stays with native Desktop and HTTP. |
| `Stop`, `SessionStart`, `SessionEnd`, `PostCompaction` | Returns an empty response and records session activity. |

Unread reminders are advisory. They never block a tool call; a model may ignore them and keep working.

## Authentication and failure

`hook.py` forwards each event to the daemon over loopback HTTP with either the run token (`x-autonom-run`) or the session's MCP capability (`x-autonom-mcp`). Both are injected by the daemon when it starts the CLI.

| Condition | Result |
| --- | --- |
| Valid run or MCP credential | The event is processed. |
| Neither, coordination tool | Blocked: `Only sessions started by Autonom may use Autonom tools`. |
| Neither, other tool | The hook returns an empty response without touching coordination. |
| Daemon unreachable | `PreToolUse` and `PermissionRequest` fail closed; other events pass through. |

A missing or invalid policy file fails the same way: the call is blocked with the parse error rather than allowed.

## HTTP surface

```sh
GET  /api/policy?directory=<workspace>          # parsed rules, or 503 with the reason
POST /api/policy/check                          # {"directory", "tool", "input"} -> {"denied", "reason"}
POST /api/hooks/pre-tool-use
POST /api/hooks/post-tool-use
POST /api/hooks/permission-request
POST /api/hooks/user-prompt-submit
POST /api/hooks/post-compaction
POST /api/hooks/session-start
POST /api/hooks/session-end
POST /api/hooks/stop
```

`/api/policy/check` runs the same engine without a session, which is how the Command Center's Policy page inspects a workspace.

## Reading more

- [Sessions](SESSIONS.md) — permission requests that policy is separate from.
- [Coordination](COORDINATION.md) — the events hooks surface to profiles.
- [Daemon architecture](DAEMON.md) — configuration and deployment.