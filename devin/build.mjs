import { build } from "esbuild";
import { readdir, rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const devin = dirname(fileURLToPath(import.meta.url));
const launcher = join(devin, "launcher");
const dist = join(resolve(devin, ".."), "dist");

const common = {
    bundle: true,
    sourcemap: false,
    target: "es2022",
    logLevel: "info",
    mainFields: ["module", "main"],
};
await Promise.all([
    build({
        ...common,
        entryPoints: [join(devin, "benchmarks/startup.ts")],
        outfile: join(dist, "benchmarks/startup.js"),
        platform: "node",
        format: "cjs",
    }),
    build({
        ...common,
        entryPoints: [join(devin, "benchmarks/run.ts")],
        outfile: join(dist, "benchmarks/sidebar.js"),
        platform: "node",
        format: "cjs",
    }),
    build({
        ...common,
        entryPoints: [join(launcher, "app.ts")],
        outfile: join(dist, "launcher.js"),
        platform: "node",
        format: "cjs",
        loader: { ".svg": "text", ".css": "text" },
    }),
    build({
        ...common,
        entryPoints: [join(launcher, "center/runtime.ts")],
        outfile: join(dist, "runtime.js"),
        platform: "browser",
        format: "iife",
        globalName: "AutonomRuntime",
        loader: { ".svg": "text", ".css": "text" },
    }),
    build({
        ...common,
        entryPoints: [join(launcher, "desktop/check.ts")],
        outfile: join(dist, "build.js"),
        platform: "node",
        format: "cjs",
        loader: { ".svg": "text", ".css": "text" },
    }),
]);
async function testFiles(directory)
{
    const ret = [];
    for (const entry of await readdir(directory, { withFileTypes: true }))
    {
        const path = join(directory, entry.name);
        if (entry.isDirectory())
            ret.push(...await testFiles(path));
        else if (entry.name.endsWith(".ts"))
            ret.push(path);
    }

    return ret;
}

await rm(join(dist, "tests"), { recursive: true, force: true });
for (const suite of ["unit", "integration"])
{
    const tests = await testFiles(join(devin, "tests", suite));
    if (tests.length)
    {
        await build({
            ...common,
            entryPoints: tests,
            outbase: join(devin, "tests", suite),
            outdir: join(dist, "tests", suite),
            platform: "node",
            format: "cjs",
            loader: { ".svg": "text", ".css": "text" },
        });
    }
}
