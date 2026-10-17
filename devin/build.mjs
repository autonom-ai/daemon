import { build } from "esbuild";
import { readdir } from "node:fs/promises";
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
        entryPoints: [join(launcher, "launcher.ts")],
        outfile: join(dist, "launcher.js"),
        platform: "node",
        format: "cjs",
        loader: { ".svg": "text", ".css": "text" },
    }),
    build({
        ...common,
        entryPoints: [join(launcher, "runtime.ts")],
        outfile: join(dist, "runtime.js"),
        platform: "browser",
        format: "iife",
        globalName: "AutonomRuntime",
        loader: { ".svg": "text", ".css": "text" },
    }),
    build({
        ...common,
        entryPoints: [join(launcher, "buildcli.ts")],
        outfile: join(dist, "build.js"),
        platform: "node",
        format: "cjs",
        loader: { ".svg": "text", ".css": "text" },
    }),
]);
for (const suite of ["unit", "integration"])
{
    const tests = (await readdir(join(devin, "tests", suite))).filter((name) => name.endsWith(".ts"));
    if (tests.length)
        await build({
            ...common,
            entryPoints: tests.map((name) => join(devin, "tests", suite, name)),
            outdir: join(dist, "tests", suite),
            platform: "node",
            format: "cjs",
            loader: { ".svg": "text", ".css": "text" },
        });
}
