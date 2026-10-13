export function object(value: unknown): Record<string, unknown> | undefined
{
    return typeof value === "object" && value !== null && !Array.isArray(value)
        ? value as Record<string, unknown> : undefined;
}

export function text(value: unknown, fallback = ""): string
{
    return typeof value === "string" ? value : fallback;
}
