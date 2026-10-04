import { generateText, jsonSchema, Output } from "ai";
import type { JSONValue, LanguageModel, ModelMessage, Provider } from "ai";

import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DEFAULT_TIMEOUT = 30_000;

type ProviderSpec = {
    npm: string;
    factory?: string;
    key?: string;
    baseURL?: string;
    options?: Record<string, unknown>;
};

const PROVIDERS: Record<string, ProviderSpec> = {
    openrouter: {
        npm: "@ai-sdk/openai-compatible",
        key: "OPENROUTER_API_KEY",
        baseURL: "https://openrouter.ai/api/v1",
        options: { name: "openrouter", supportsStructuredOutputs: true },
    },
    zen: {
        npm: "@ai-sdk/openai-compatible",
        key: "OPENCODE_API_KEY",
        baseURL: "https://opencode.ai/zen/v1",
        options: { name: "zen", supportsStructuredOutputs: true },
    },
    anthropic: { npm: "@ai-sdk/anthropic", key: "ANTHROPIC_API_KEY" },
    codex: { npm: "@ai-sdk/openai", key: "OPENAI_API_KEY" },
    local: {
        npm: "@ai-sdk/openai-compatible",
        baseURL: "http://localhost:11434/v1",
        options: { name: "local" },
    },
};

const MODELS: Record<string, string> = { policy: "openrouter/openai/gpt-5-mini" };
const DEFAULT_MODEL = "openrouter/openai/gpt-5-mini";

type GatewayRequest = {
    model?: string;
    system?: string;
    prompt?: string;
    messages?: ModelMessage[];
    schema?: Parameters<typeof jsonSchema>[0];
    timeout?: number;
    maxRetries?: number;
    maxOutputTokens?: number;
    providerOptions?: Record<string, Record<string, JSONValue>>;
};

async function readInput(): Promise<GatewayRequest>
{
    let raw = "";
    for await (const chunk of process.stdin)
        raw += chunk;

    return JSON.parse(raw) as GatewayRequest;
}

async function loadDotenv(): Promise<void>
{
    let raw: string;
    try
    {
        raw = await readFile(resolve(ROOT, ".env"), "utf8");
    }
    catch
    {
        return;
    }

    for (const line of raw.split("\n"))
    {
        const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
        if (!match || process.env[match[1]!] !== undefined)
            continue;

        let value = match[2]!;
        if (value.length >= 2 && (value[0] === "\"" || value[0] === "'") && value.at(-1) === value[0])
            value = value.slice(1, -1);
        else
            value = value.replace(/\s+#.*$/, "").trim();
        process.env[match[1]!] = value;
    }
}

async function createProvider(name: string, spec: ProviderSpec): Promise<Provider>
{
    let mod: Record<string, unknown>;
    try
    {
        mod = (await import(spec.npm)) as Record<string, unknown>;
    }
    catch
    {
        throw new Error(`Provider ${name} requires ${spec.npm} (run: npm install ${spec.npm})`);
    }

    const factoryName = spec.factory ?? Object.keys(mod).find(
        (key) => /^create[A-Z]/.test(key) && typeof mod[key] === "function"
    );
    const factory = factoryName !== undefined ? mod[factoryName] : undefined;
    if (typeof factory !== "function")
        throw new Error(`Provider ${name} needs a "factory" in PROVIDERS (npm: ${spec.npm})`);

    const options = { ...spec.options };
    if (spec.key !== undefined)
    {
        const apiKey = process.env[spec.key];
        if (apiKey === undefined)
            throw new Error(`Provider ${name} requires ${spec.key} (set it in .env)`);
        options.apiKey = apiKey;
    }
    if (spec.baseURL !== undefined)
        options.baseURL = process.env[`AUTONOM_${name.toUpperCase()}_BASE_URL`] ?? spec.baseURL;

    return (factory as (options: Record<string, unknown>) => Provider)(options);
}

function modelSpec(request: GatewayRequest): { provider: string; id: string }
{
    const spec = MODELS[request.model ?? ""] ?? request.model ?? DEFAULT_MODEL;
    const slash = typeof spec === "string" ? spec.indexOf("/") : -1;
    if (slash < 1 || slash === spec!.length - 1)
        throw new Error(`Unknown model ${request.model ?? "default"} (use provider/model)`);

    return { provider: spec!.slice(0, slash), id: spec!.slice(slash + 1) };
}

async function resolveModel(request: GatewayRequest): Promise<LanguageModel>
{
    const { provider: name, id } = modelSpec(request);
    const spec = PROVIDERS[name];
    if (!spec)
        throw new Error(`Unknown provider ${name} (supported: ${Object.keys(PROVIDERS).join(", ")})`);

    return (await createProvider(name, spec)).languageModel(id);
}

async function main(): Promise<void>
{
    await loadDotenv();
    const request = await readInput();
    if (request.prompt !== undefined && request.messages !== undefined)
        throw new Error("The gateway request takes a prompt or messages, not both");
    if (request.prompt === undefined && !request.messages?.length)
        throw new Error("The gateway request needs a prompt or messages");

    const shared = {
        model: await resolveModel(request),
        abortSignal: AbortSignal.timeout(request.timeout ?? DEFAULT_TIMEOUT),
        ...(request.system !== undefined ? { system: request.system } : {}),
        ...(request.maxRetries !== undefined ? { maxRetries: request.maxRetries } : {}),
        ...(request.maxOutputTokens !== undefined ? { maxOutputTokens: request.maxOutputTokens } : {}),
        ...(request.providerOptions !== undefined ? { providerOptions: request.providerOptions } : {}),
    };
    const options =
        request.prompt !== undefined
            ? { ...shared, prompt: request.prompt }
            : { ...shared, messages: request.messages! };

    if (request.schema !== undefined)
    {
        const result = await generateText({
            ...options,
            output: Output.object({ schema: jsonSchema(request.schema) }),
        });
        process.stdout.write(
            JSON.stringify({ output: result.output ?? null, finishReason: result.finishReason, usage: result.usage })
        );
        return;
    }

    const result = await generateText(options);
    process.stdout.write(
        JSON.stringify({ text: result.text, finishReason: result.finishReason, usage: result.usage })
    );
}

main().catch((error: unknown) =>
{
    process.stderr.write(`Gateway request failed: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
});
