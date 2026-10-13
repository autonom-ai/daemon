#!/usr/bin/env node
// Verify the Autonom patch pipeline against the real Devin Desktop bundles in a sandbox:
//   - upgrades the currently deployed legacy patch generation back to pristine
//   - proves pristine reconstruction is byte-exact against sessions.desktop.main.js.autonom.orig
//   - applies the V3 patch, parses both patched bundles with esbuild
//   - restores bit-for-bit and compares against the pre-patch sandbox copies
//
//   node scripts/verify-patch.mjs
//
// The live installation is never modified; everything happens in a temp copy.

import { createRequire } from "node:module";
import { cp, mkdtemp, readFile, rm, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const { build, transform } = require(join(repoRoot, "extension/node_modules/esbuild"));

const APP_ROOT = process.env.AUTONOM_APP_ROOT || "/usr/share/devin-desktop/resources/app";
const WB_REL = join("out", "vs", "workbench", "windsurf-chat-client", "index.js");
const SESS_REL = join("out", "vs", "sessions", "sessions.desktop.main.js");
const SESS_HTML_REL = join("out", "vs", "sessions", "electron-browser", "sessions.html");

function fail(message) {
    console.error(`FAIL: ${message}`);
    process.exitCode = 1;
}

const modulePath = join(tmpdir(), `autonom-patch-module-${process.pid}.mjs`);
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

const sandbox = await mkdtemp(join(tmpdir(), "autonom-patch-sandbox-"));
try {
    const wbPath = join(sandbox, WB_REL);
    const sessPath = join(sandbox, SESS_REL);
    const htmlPath = join(sandbox, SESS_HTML_REL);
    await mkdir(dirname(wbPath), { recursive: true });
    await mkdir(dirname(sessPath), { recursive: true });
    await mkdir(dirname(htmlPath), { recursive: true });
    await cp(join(APP_ROOT, WB_REL), wbPath);
    await cp(join(APP_ROOT, SESS_REL), sessPath);
    if (existsSync(join(APP_ROOT, SESS_HTML_REL))) {
        await cp(join(APP_ROOT, SESS_HTML_REL), htmlPath);
    }

    const legacyWb = await readFile(wbPath, "utf8");
    const legacySess = await readFile(sessPath, "utf8");
    const manager = new patch.PatchManager(sandbox);

    const result = await manager.ensurePatched();
    if (!result.applied) {
        fail(`ensurePatched did not apply: ${result.error}`);
    }

    const patchedWb = await readFile(wbPath, "utf8");
    const patchedSess = await readFile(sessPath, "utf8");
    for (const [name, content] of [["workbench", patchedWb], ["sessions", patchedSess]]) {
        for (const marker of [patch.MARKER_V4, patch.MARKER_P1, patch.MARKER_P2, patch.MARKER_P3, patch.MARKER_TOGGLE]) {
            if (!content.includes(marker)) {
                fail(`${name} bundle missing marker ${marker}`);
            }
        }
        for (const legacy of [patch.MARKER_V1, patch.MARKER_V2, patch.MARKER_V3]) {
            if (content.includes(legacy)) {
                fail(`${name} bundle still contains legacy marker ${legacy}`);
            }
        }
        if (!content.includes("agent-editor-switch") || !content.includes("autonom.version.json")) {
            fail(`${name} bundle missing the PoC switch markup or hot-patch version polling`);
        }
        if (!content.includes('data-autonom-slot":"sidebar"') || !content.includes('data-autonom-slot":"center"')) {
            fail(`${name} bundle missing React-owned slots`);
        }
    }

    // The sandbox copies are the currently deployed legacy patch generation. Both the
    // legacy content and the freshly patched content must reconstruct to the same
    // pristine vendor bundle; the sessions .autonom.orig on disk is the ground truth.
    const pristineFromLegacyWb = manager.reconstructPristine(legacyWb, patch.WORKBENCH_BUNDLE_CONFIG);
    const expectedWb = manager.reconstructPristine(patchedWb, patch.WORKBENCH_BUNDLE_CONFIG);
    const expectedSess = manager.reconstructPristine(patchedSess, patch.SESSIONS_BUNDLE_CONFIG);
    if (expectedWb === undefined) fail("workbench pristine reconstruction failed");
    if (expectedSess === undefined) fail("sessions pristine reconstruction failed");
    if (pristineFromLegacyWb === undefined) {
        fail("workbench pristine reconstruction from the legacy patch failed");
    } else if (pristineFromLegacyWb !== expectedWb) {
        fail("workbench legacy and V3 reconstructions disagree");
    } else {
        console.log("PASS: workbench legacy and V3 reconstructions agree on the pristine bundle");
    }
    const sessionsBackupPath = `${join(APP_ROOT, SESS_REL)}.autonom.orig`;
    if (existsSync(sessionsBackupPath) && expectedSess !== undefined) {
        const groundTruth = await readFile(sessionsBackupPath, "utf8");
        const pristineFromLegacySess = manager.reconstructPristine(legacySess, patch.SESSIONS_BUNDLE_CONFIG);
        if (expectedSess !== groundTruth || pristineFromLegacySess !== groundTruth) {
            fail("sessions pristine reconstruction is not byte-exact against the .autonom.orig ground truth");
        } else {
            console.log("PASS: sessions pristine reconstruction is byte-exact against .autonom.orig");
        }
    } else if (!existsSync(sessionsBackupPath)) {
        console.log("NOTE: no sessions .autonom.orig ground truth present; skipped byte-exact check");
    }

    for (const [name, content] of [["workbench", patchedWb], ["sessions", patchedSess]]) {
        try {
            await transform(content, { loader: "js", format: "esm" });
            console.log(`PASS: patched ${name} bundle parses`);
        } catch (error) {
            fail(`patched ${name} bundle does not parse: ${error.message}`);
        }
    }

    const restored = await manager.restoreOriginal();
    if (!restored.restored) {
        fail(`restore failed: ${restored.error}`);
    }
    if (expectedWb !== undefined && (await readFile(wbPath, "utf8")) !== expectedWb) {
        fail("restored workbench is not bit-for-bit against the reconstructed pristine content");
    }
    if (expectedSess !== undefined && (await readFile(sessPath, "utf8")) !== expectedSess) {
        fail("restored sessions is not bit-for-bit against the reconstructed pristine content");
    }
    console.log("PASS: restore is bit-for-bit against the reconstructed pristine content");

    // Second cycle: upgrade path from the V3 patch back to pristine and re-patch.
    const again = await manager.ensurePatched();
    if (!again.applied && !again.alreadyPatched) {
        fail(`second ensurePatched failed: ${again.error}`);
    }
    const cycle = manager.reconstructPristine(await readFile(wbPath, "utf8"), patch.WORKBENCH_BUNDLE_CONFIG);
    if (cycle === undefined) {
        fail("workbench V3 reconstruction failed on second cycle");
    } else {
        console.log("PASS: workbench V3 patch reconstructs to pristine");
    }
} finally {
    await rm(sandbox, { recursive: true, force: true });
    await rm(modulePath, { force: true });
}

console.log(process.exitCode ? "verify-patch: FAILED" : "verify-patch: OK");
