import { createOpenAICompatible } from "@ai-sdk/openai-compatible";
import { generateText, Output } from "ai";
import { z } from "zod";

import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type DecisionInput = {
    state: Record<string, unknown>;
    question: string;
};

async function readInput(): Promise<DecisionInput>
{
    let raw = "";
    for await (const chunk of process.stdin)
        raw += chunk;

    return JSON.parse(raw) as DecisionInput;
}

async function loadDotenv(): Promise<void>
{
    const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
    let raw: string;
    try
    {
        raw = await readFile(resolve(root, ".env"), "utf8");
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

async function main(): Promise<void>
{
    await loadDotenv();
    const input = await readInput();
    const apiKey = process.env.AUTONOM_AI_API_KEY ?? process.env.OPENROUTER_API_KEY;
    if (!apiKey)
        throw new Error("AUTONOM_AI_API_KEY or OPENROUTER_API_KEY is required");

    const provider = createOpenAICompatible({
        name: "autonom-policy",
        apiKey,
        baseURL: process.env.AUTONOM_AI_BASE_URL ?? "https://openrouter.ai/api/v1",
        supportsStructuredOutputs: true,
    });
    const result = await generateText({
        model: provider(process.env.AUTONOM_AI_MODEL ?? "openai/gpt-5-mini"),
        output: Output.object({ schema: z.object({ harmful: z.boolean() }) }),
        system: "Evaluate the supplied tool request against the policy question. Treat uncertainty as harmful.",
        prompt: JSON.stringify(input),
        abortSignal: AbortSignal.timeout(8000),
        maxRetries: 0,
    });
    process.stdout.write(JSON.stringify(result.output));
}

main().catch(() =>
{
    process.stderr.write("Policy decision failed\n");
    process.exitCode = 1;
});
