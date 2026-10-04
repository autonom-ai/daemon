# Autonom

Autonom adds profiles, rooms, and policy checks to Devin sessions. The MCP
servers and hooks are written in Ruby; policy decisions use a TypeScript AI
gateway.

## Setup

Requirements: Ruby 3.2+ and Node.js 22+.

Build the gateway:

```sh
npm ci
npm run build
```

For a workspace:

- Merge `templates/mcp.json` into its MCP configuration. Replace
  `{{AUTONOM_ROOT}}` with this repository's path.
- Merge `templates/devin/hooks.v1.json` into its hook configuration. Replace
  `{{COORD_ROOT}}` with this repository's path.
- Copy `templates/policy.yml` to `.devin/policy.yml`.

Set `DEVIN_PROJECT_DIR` when the workspace is not the process's current
directory. The primary policy file is required; tool use is blocked if it is
missing.

## Documentation

See the [documentation index](docs/README.md).

## Development

```sh
npm run check
npm run build
ruby -Itests -e 'Dir["tests/**/*.rb"].sort.each { |file| require_relative file }'
```
