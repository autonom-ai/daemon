# Policy

The workspace policy is `.devin/policy.yml`. Copy `templates/policy.yml` to
that path and edit it. The file is required: the hook blocks tool use if it is
missing or invalid.

## Permissions

`permissions` grants `read`, `write`, and `execute` to `default` or to a named
profile. A leading `-` removes a permission. Matching entries are applied in
order, so later entries override earlier ones.

```yaml
permissions:
  - default: [read, write, execute]
  - assistant: [read, -execute]
```

Path access also restricts `.env` files, other profiles' data, session
mappings, the primary policy, and private rooms.

## Rules

Rules run in order. Match fields against the tool name (`tool`) or a string in
the tool input. Patterns are regular expressions.

```yaml
rules:
  - match:
      tool: exec
      command: 'rm\s+-rf\s+/'
    action: deny
    reason: Refusing to delete the filesystem root
```

Actions are `deny`, `allow`, and `screen`. A matching `deny` blocks the request.
A matching `allow` does not block it; evaluation continues. A screen rule asks
its `question` through the policy model and blocks if the model judges the
request harmful. Private content fields are removed from model input; add field
names to `expose` to include them. `context` provides extra information to the
model.

## Secondary policies

A room's `policy.yml` is a secondary policy. Posting in a room makes that
room's policy the profile's secondary policy (`Profile.policy`), and the hook
applies it after the primary policy. Secondary policies add rules; they do not
change primary permissions.

The policy MCP exposes `check_policy`, which checks a tool request against the
primary policy and the caller's profile policy.

Room policies are plain files: members can read them, and the owner or an admin
can edit them with normal file tools. The policy MCP is separate from
coordination; both servers are in `templates/mcp.json`.
