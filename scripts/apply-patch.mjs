#!/usr/bin/env node
// Apply (or restore) the Autonom Command Center patch on the live Devin Desktop installation
// using the same PatchManager the extension host uses. Backups, SHA-256 verification, product
// checksum sync, and companion deployment all go through the production code path.
//
//   node scripts/apply-patch.mjs             # upgrade/patch both vendor bundles + deploy companion
//   node scripts/apply-patch.mjs --restore   # restore pristine vendor files and remove companion assets
//   node scripts/apply-patch.mjs --status    # report patch status only

import { createRequire } from "node:module";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const { build } = require(join(repoRoot, "extension/node_modules/esbuild"));

const APP_ROOT = process.env.AUTONOM_APP_ROOT || "/usr/share/devin-desktop/resources/app";
const mode = process.argv.includes("--restore") ? "restore" : process.argv.includes("--status") ? "status" : "patch";

const modulePath = join(tmpdir(), `autonom-patch-apply-${process.pid}.mjs`);
await build({
    entryPoints: [join(repoRoot, "extension/source/host/patch.ts")],
    outfile: modulePath,
    bundle: true,
    platform: "node",
    format: "esm",
    logLevel: "silent",
    define: { __dirname: JSON.stringify(join(repoRoot, "extension/dist")) },
});
const patch = await import(`${modulePath}?t=${Date.now()}`);

const manager = new patch.PatchManager(APP_ROOT);
try {
    if (mode === "status") {
        console.log(JSON.stringify(await manager.checkStatus(), null, 2));
    } else if (mode === "restore") {
        const result = await manager.restore();
        console.log(JSON.stringify(result, null, 2));
        if (!result.restored) process.exitCode = 1;
    } else {
        const result = await manager.ensurePatched();
        console.log(JSON.stringify(result, null, 2));
        if (!result.applied && !result.alreadyPatched) process.exitCode = 1;
        if (result.applied) console.log("Patch applied. Reload the Devin Desktop window to load the new bundle.");
    }
} finally {
    await rm(modulePath, { force: true });
}
