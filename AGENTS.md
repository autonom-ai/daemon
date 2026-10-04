# Agents

TypeScript is limited to the AI SDK bridge.

```sh
npm ci
npm run check
npm run build
ruby -Itests -e 'Dir["tests/**/*.rb"].sort.each { |file| require_relative file }'
```

Build the bridge before running tests: the decision tests exercise Ruby-to-Node
requests against a local mock provider without remote credentials.
