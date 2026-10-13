import { build } from "esbuild";
import { readdir, rm } from "node:fs/promises";

await rm("dist", { recursive: true, force: true });
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
        entryPoints: ["launcher.ts"],
        outfile: "dist/launcher.js",
        platform: "node",
        format: "cjs",
        loader: { ".svg": "text" },
    }),
    build({
        ...common,
        entryPoints: ["runtime.ts"],
        outfile: "dist/runtime.js",
        platform: "browser",
        format: "iife",
        globalName: "AutonomRuntime",
        loader: { ".svg": "text" },
    }),
]);
const tests = (await readdir("tests/unit")).filter((name) => name.endsWith(".ts"));
if (tests.length)
    await build({
        ...common,
        entryPoints: tests.map((name) => `tests/unit/${name}`),
        outdir: "dist/tests/unit",
        platform: "node",
        format: "cjs",
        loader: { ".svg": "text" },
    });
