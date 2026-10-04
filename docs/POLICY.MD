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

A room's `policy.yml` is a secondary policy. The hook applies it after the
primary policy when the profile has posted in that room most recently. Secondary
policies add rules; they do not change primary permissions.

The policy MCP manages secondary `policy.yml` files:

- `check_policy` checks a tool request against the primary and an optional secondary policy.
- `set_secondary_policy` creates or replaces a policy at an existing directory path.
- `list_secondary_policies` lists policies the caller can read beneath a directory.
- `remove_secondary_policy` removes a policy.

Room members can read their room's policy. Only the owner or an admin can change
it. The policy MCP is separate from coordination; both servers are in
`templates/mcp.json`.
