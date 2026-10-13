import { build } from "esbuild";
import { copyFile, mkdir, readdir } from "node:fs/promises";

await mkdir("dist/tests", { recursive: true });
await mkdir("dist/commandCenter", { recursive: true });
await copyFile("../LICENSE.txt", "LICENSE.txt");
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
        entryPoints: ["source/main.ts"],
        outfile: "dist/extension.js",
        platform: "node",
        external: ["vscode"],
    }),
    build({
        ...common,
        entryPoints: ["source/commandCenter/index.ts"],
        outfile: "dist/commandCenter/autonom.bundle.js",
        platform: "browser",
        format: "esm",
    }),
    build({
        ...common,
        entryPoints: ["source/commandCenter/native.ts"],
        outfile: "dist/commandCenter/native.js",
        platform: "browser",
        format: "iife",
        globalName: "AutonomNative",
    }),
    build({
        ...common,
        entryPoints: ["source/webview/index.ts"],
        outfile: "dist/commandCenter/ui.js",
        platform: "browser",
        format: "iife",
    }),
]);
await copyFile("media/commandCenter.css", "dist/commandCenter/autonom.sessions.css");
await copyFile("media/autonom.ui.css", "dist/commandCenter/ui.css");
const tests = (await readdir("tests/unit")).filter((name) => name.endsWith(".ts"));
if (tests.length)
    await build({ ...common, entryPoints: tests.map((name) => "tests/unit/" + name), outdir: "dist/tests", platform: "node" });
