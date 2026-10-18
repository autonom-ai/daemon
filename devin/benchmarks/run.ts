import { benchmark, summary } from "./sidebar";

async function main(): Promise<void>
{
    const target = process.argv[2];
    if (!target)
        throw new Error("Usage: node dist/benchmarks/sidebar.js <separate-workbench-target-id>");

    const sample = await benchmark(target);
    process.stdout.write(JSON.stringify({ target, ...sample,
        summary: { update: summary(sample.update), heartbeat: summary(sample.heartbeat) } }, null, 2) + "\n");
}

void main().catch((error: unknown) =>
{
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
});
