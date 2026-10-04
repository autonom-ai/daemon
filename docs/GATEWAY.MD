# Gateway

`source/gateway.rb` sends JSON requests to `node dist/gateway.js`. Build the
gateway with `npm run build` before running policy decisions. The TypeScript
bridge uses the Vercel AI SDK.

## Request

A request is one JSON object on stdin. Set exactly one of `prompt` or `messages`.

| Field | Purpose |
| --- | --- |
| `model` | Provider/model name or alias. The `policy` alias uses `openrouter/openai/gpt-5-mini`. |
| `prompt`, `messages` | Text prompt or AI SDK message list. |
| `system` | Optional system message. |
| `schema` | Optional JSON schema; returns `output` instead of `text`. |
| `timeout` | Timeout in milliseconds. Default: 30000. |
| `maxRetries` | Provider retry count. |
| `maxOutputTokens` | Output token limit. |
| `providerOptions` | Provider-specific options. |

The bridge writes one JSON response to stdout. Responses contain `text` or
`output`, plus the finish reason and usage.

## Providers

| Provider | Model prefix | Key |
| --- | --- | --- |
| OpenRouter | `openrouter/` | `OPENROUTER_API_KEY` |
| Zen | `zen/` | `OPENCODE_API_KEY` |
| Anthropic | `anthropic/` | `ANTHROPIC_API_KEY` |
| OpenAI | `openai/` | `OPENAI_API_KEY` |
| Local | `local/` | None; defaults to `http://localhost:11434/v1` |

Set keys in the environment or in the repository's `.env`; environment values
take precedence. Override configured base URLs with `AUTONOM_OPENROUTER_BASE_URL`,
`AUTONOM_ZEN_BASE_URL`, or `AUTONOM_LOCAL_BASE_URL`.
