import {
    BOOTSTRAP_HEADER,
    MARKER_V4,
    computeProductChecksum,
    computeSha256,
    PatchManager,
    WORKBENCH_BUNDLE_CONFIG,
} from "../../source/host/patch";
import { writePrivateFile } from "../../source/host/files";
import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const SESSIONS_HOOK_SLOT = `_.jsx)(nft,{children:(0,_.jsxs)(ift,{ariaLabel:"New session",isActive:a,variant:"nav",elem`;
const WORKBENCH_HOOK_SLOT = `tX.jsx)(rNj,{children:(0,tX.jsxs)(rNG,{ariaLabel:"New session",isActive:a,variant:"nav",elem`;
const SESSIONS_HOOK2_SLOT = 'children:[jY,(0,_.jsx)(eft,{children:(0,_.jsx)(YY1,{ref:Tm,className:"static z-auto bg-transparent",label:"Spaces"';
const SESSIONS_HOOK3_SLOT = 'children:[(0,_.jsx)(vsu,{}),(0,_.jsx)(WTr,{})]';
const SESSIONS_HOOK2_TAIL = 'Sv(null)}})]})})})},bsu="session-repo-filter"';
const WORKBENCH_HOOK2_SLOT = 'children:[tg,(0,tX.jsx)(rNR,{children:(0,tX.jsx)(rDI,{ref:eU,className:"static z-auto bg-transparent",label:"Spaces"';
const WORKBENCH_HOOK3_SLOT = 'children:[(0,tX.jsx)(iqs,{}),(0,tX.jsx)(ewt,{})]';
const WORKBENCH_HOOK2_TAIL = 'td(null)}})]})})})},iql="session-repo-filter"';

function createMockBundle(hook = SESSIONS_HOOK_SLOT): string {
    const isWorkbench = hook === WORKBENCH_HOOK_SLOT;
    const hook2 = isWorkbench ? WORKBENCH_HOOK2_SLOT : SESSIONS_HOOK2_SLOT;
    const hook2Tail = isWorkbench ? WORKBENCH_HOOK2_TAIL : SESSIONS_HOOK2_TAIL;
    const hook3 = isWorkbench ? WORKBENCH_HOOK3_SLOT : SESSIONS_HOOK3_SLOT;
    return `"use strict";define(["require","exports"],function(e,t){var a=true;return (0,${hook}:null}))});${hook2};var x=1;${hook2Tail};${hook3};`;
}

async function fixture(opts: { sessions?: boolean; workbench?: boolean } = { sessions: true }): Promise<{
    directory: string;
    bundlePath: string;
    backupPath: string;
    workbenchBundlePath: string;
    workbenchBackupPath: string;
    close: () => Promise<void>;
}> {
    const directory = await mkdtemp(join(tmpdir(), "autonom-patch-test-"));
    const bundleDir = join(directory, "out", "vs", "sessions");
    const bundlePath = join(bundleDir, "sessions.desktop.main.js");
    const backupPath = `${bundlePath}.autonom.orig`;

    const wbDir = join(directory, "out", "vs", "workbench", "windsurf-chat-client");
    const workbenchBundlePath = join(wbDir, "index.js");
    const workbenchBackupPath = `${workbenchBundlePath}.autonom.orig`;

    if (opts.sessions !== false) {
        await writePrivateFile(bundlePath, createMockBundle(SESSIONS_HOOK_SLOT));
    }
    if (opts.workbench) {
        await writePrivateFile(workbenchBundlePath, createMockBundle(WORKBENCH_HOOK_SLOT));
    }

    return {
        directory,
        bundlePath,
        backupPath,
        workbenchBundlePath,
        workbenchBackupPath,
        close: () => rm(directory, { recursive: true, force: true }),
    };
}

test("PatchManager adds loopback access to workbench CSP and restores it", async () => {
    const env = await fixture({ sessions: false, workbench: true });
    const htmlPath = join(env.directory, "out", "vs", "code", "electron-browser", "workbench", "workbench.html");
    const originalHtml = '<!DOCTYPE html><html><head><meta http-equiv="Content-Security-Policy" content="default-src \'self\'; connect-src \'self\';"></head></html>';
    try {
        await writePrivateFile(htmlPath, originalHtml);
        const manager = new PatchManager(env.directory);
        const patched = await manager.ensurePatched();
        assert.equal(patched.applied, true);
        const patchedHtml = await readFile(htmlPath, "utf8");
        assert.ok(patchedHtml.includes("connect-src http://127.0.0.1:* http://localhost:*"));

        const restored = await manager.restoreOriginal();
        assert.equal(restored.restored, true);
        assert.equal(await readFile(htmlPath, "utf8"), originalHtml);
    } finally {
        await env.close();
    }
});

test("PatchManager detects target bundle and matches vendor hook string", async () => {
    const env = await fixture();
    try {
        const manager = new PatchManager(env.directory);
        assert.equal(manager.getTargetPath(), env.bundlePath);
        assert.equal(await manager.isPatched(), false);

        const content = await readFile(env.bundlePath, "utf8");
        assert.ok(content.includes(SESSIONS_HOOK_SLOT));
    } finally {
        await env.close();
    }
});

test("PatchManager detects workbench target bundle and matches vendor hook string", async () => {
    const env = await fixture({ sessions: false, workbench: true });
    try {
        const manager = new PatchManager(env.directory);
        assert.equal(manager.getTargetPath(), env.workbenchBundlePath);
        assert.equal(await manager.isPatched(), false);

        const content = await readFile(env.workbenchBundlePath, "utf8");
        assert.ok(content.includes(WORKBENCH_HOOK_SLOT));
    } finally {
        await env.close();
    }
});

test("PatchManager creates atomic backup before applying surgical micro-hook", async () => {
    const env = await fixture();
    try {
        const manager = new PatchManager(env.directory);
        const originalContent = await readFile(env.bundlePath, "utf8");
        const originalSha = computeSha256(originalContent);

        const result = await manager.ensurePatched();
        assert.equal(result.applied, true);

        // Backup file exists and has bit-for-bit identical SHA-256 to original vendor content
        const backupContent = await readFile(env.backupPath, "utf8");
        assert.equal(computeSha256(backupContent), originalSha);
        assert.equal(backupContent, originalContent);

        // Target file contains injection
        const patchedContent = await readFile(env.bundlePath, "utf8");
        assert.ok(patchedContent.includes("__autonom_provider_toggle"));
        assert.equal(await manager.isPatched(), true);
    } finally {
        await env.close();
    }
});

test("PatchManager applies dual-bundle patches simultaneously and verifies SHA-256 for both", async () => {
    const env = await fixture({ sessions: true, workbench: true });
    try {
        const manager = new PatchManager(env.directory);
        const origSessions = await readFile(env.bundlePath, "utf8");
        const origWorkbench = await readFile(env.workbenchBundlePath, "utf8");
        const origSessionsSha = computeSha256(origSessions);
        const origWorkbenchSha = computeSha256(origWorkbench);

        const result = await manager.ensurePatched();
        assert.equal(result.applied, true);

        // Both backups exist and have identical SHA-256 hashes
        const backupSessions = await readFile(env.backupPath, "utf8");
        const backupWorkbench = await readFile(env.workbenchBackupPath, "utf8");
        assert.equal(computeSha256(backupSessions), origSessionsSha);
        assert.equal(computeSha256(backupWorkbench), origWorkbenchSha);

        // Both target files contain respective JSX injections
        const patchedSessions = await readFile(env.bundlePath, "utf8");
        const patchedWorkbench = await readFile(env.workbenchBundlePath, "utf8");
        assert.ok(patchedSessions.includes("wrapNewSession?.(_)"));
        assert.ok(patchedWorkbench.includes("wrapNewSession?.(tX)"));
        assert.equal(await manager.isPatched(), true);

        // Rollback restores both bit-for-bit
        const rollback = await manager.restoreOriginal();
        assert.equal(rollback.restored, true);

        const restoredSessions = await readFile(env.bundlePath, "utf8");
        const restoredWorkbench = await readFile(env.workbenchBundlePath, "utf8");
        assert.equal(computeSha256(restoredSessions), origSessionsSha);
        assert.equal(computeSha256(restoredWorkbench), origWorkbenchSha);
        assert.equal(await manager.isPatched(), false);
    } finally {
        await env.close();
    }
});

test("PatchManager application is strictly idempotent", async () => {
    const env = await fixture();
    try {
        const manager = new PatchManager(env.directory);
        const res1 = await manager.ensurePatched();
        assert.equal(res1.applied, true);

        const contentAfterFirst = await readFile(env.bundlePath, "utf8");

        // Second call should not re-patch or duplicate injection
        const res2 = await manager.ensurePatched();
        assert.equal(res2.applied, false);
        assert.equal(res2.alreadyPatched, true);

        const contentAfterSecond = await readFile(env.bundlePath, "utf8");
        assert.equal(contentAfterSecond, contentAfterFirst);
    } finally {
        await env.close();
    }
});

test("PatchManager rollback cleanly restores pristine vendor bundle bit-for-bit", async () => {
    const env = await fixture();
    try {
        const manager = new PatchManager(env.directory);
        const pristine = await readFile(env.bundlePath, "utf8");
        const pristineSha = computeSha256(pristine);

        await manager.ensurePatched();
        assert.equal(await manager.isPatched(), true);

        const rollback = await manager.restoreOriginal();
        assert.equal(rollback.restored, true);

        const restoredContent = await readFile(env.bundlePath, "utf8");
        assert.equal(computeSha256(restoredContent), pristineSha);
        assert.equal(restoredContent, pristine);
        assert.equal(await manager.isPatched(), false);
    } finally {
        await env.close();
    }
});

test("PatchManager handles read-only unwritable bundle without throwing unhandled exceptions", async () => {
    const env = await fixture();
    try {
        // Remove write permissions
        await chmod(env.bundlePath, 0o444);

        const manager = new PatchManager(env.directory);
        const status = await manager.checkStatus();
        assert.equal(status.writable, false);
        assert.ok(status.error?.includes("Write permission denied"));

        const result = await manager.ensurePatched();
        assert.equal(result.applied, false);
        assert.equal(result.writable, false);
        assert.ok(result.error?.includes("Write permission denied"));

        // Restore permission for clean fixture teardown
        await chmod(env.bundlePath, 0o644);
    } finally {
        await env.close();
    }
});

test("PatchManager rejects corrupted or mismatched vendor bundles without throwing uncaught fatal errors", async () => {
    const env = await fixture();
    try {
        // Corrupt vendor bundle with missing hook
        await writeFile(env.bundlePath, "console.log('mismatched bundle');", "utf8");

        const manager = new PatchManager(env.directory);
        const result = await manager.ensurePatched();

        assert.equal(result.applied, false);
        assert.ok(result.error?.includes("Vendor hook slot not found"));
        // Backup should NOT be created for corrupt bundle
        await assert.rejects(() => readFile(env.backupPath));
    } finally {
        await env.close();
    }
});

test("PatchManager micro-hook does not perform broken static imports and uses defensive dynamic loader", async () => {
    const env = await fixture();
    try {
        const manager = new PatchManager(env.directory);
        const result = await manager.ensurePatched();
        assert.equal(result.applied, true);

        const patchedContent = await readFile(env.bundlePath, "utf8");

        // Verify static import is completely absent
        assert.equal(
            patchedContent.includes('import "./autonom.bundle.js";'),
            false,
            "Must NOT contain static import which breaks module loading on missing files"
        );

        // Verify self-contained inline bootstrap is present
        assert.ok(patchedContent.includes("globalThis.__autonom="));
        assert.ok(patchedContent.includes("wrapNewSession:"));
        assert.ok(patchedContent.includes("isAutonomActive:"));

        // Verify the companion is loaded through a guarded dynamic import with a version query
        assert.ok(patchedContent.includes('"./autonom.bundle.js"'));
        assert.ok(patchedContent.includes("import(companionUrl(version))"));
        assert.ok(patchedContent.includes(".catch("));
    } finally {
        await env.close();
    }
});

test("PatchManager respects Trusted Types with zero raw innerHTML string assignments", async () => {
    const env = await fixture({ sessions: true, workbench: true });
    try {
        const manager = new PatchManager(env.directory);
        await manager.ensurePatched();

        const patchedSessions = await readFile(env.bundlePath, "utf8");
        const patchedWorkbench = await readFile(env.workbenchBundlePath, "utf8");

        // Assert zero innerHTML in bootstrap and injected code
        assert.equal(BOOTSTRAP_HEADER.includes("innerHTML"), false, "BOOTSTRAP_HEADER must not contain innerHTML");
        assert.equal(BOOTSTRAP_HEADER.includes("outerHTML"), false, "BOOTSTRAP_HEADER must not contain outerHTML");
        assert.equal(BOOTSTRAP_HEADER.includes("document.write"), false, "BOOTSTRAP_HEADER must not contain document.write");

        assert.ok(patchedSessions.includes("wrapNewSession"));
        assert.ok(patchedWorkbench.includes("wrapNewSession"));
    } finally {
        await env.close();
    }
});

test("PatchManager deployCompanion copies shared assets beside both session entry points", async () => {
    const env = await fixture({ sessions: true, workbench: true });
    try {
        const manager = new PatchManager(env.directory);
        const sessionsDir = manager.getSessionsDir();
        const electronBrowserDir = join(sessionsDir, "electron-browser");
        const mockContext = {
            asAbsolutePath: (rel: string) => join(env.directory, rel),
        };
        const srcBundle = join(env.directory, "dist", "commandCenter", "autonom.bundle.js");
        const srcCss = join(env.directory, "dist", "commandCenter", "autonom.sessions.css");
        await writePrivateFile(srcBundle, "export function init() {}");
        await writePrivateFile(srcCss, ".provider-toggle { color: red; }");

        const managerWithContext = new PatchManager(mockContext);
        (managerWithContext as any).sessionsDir = sessionsDir;
        (managerWithContext as any).mainJsPath = env.bundlePath;
        (managerWithContext as any).backupPath = env.backupPath;
        await managerWithContext.ensurePatched();

        const expectedVersion = computeSha256(Buffer.from("export function init() {}", "utf8")).slice(0, 16);
        const deployed = [sessionsDir, electronBrowserDir];
        for (const directory of deployed) {
            assert.equal(await readFile(join(directory, "autonom.bundle.js"), "utf8"), "export function init() {}");
            assert.equal(await readFile(join(directory, "autonom.sessions.css"), "utf8"), ".provider-toggle { color: red; }");
            const version = JSON.parse(await readFile(join(directory, "autonom.version.json"), "utf8"));
            assert.equal(version.version, expectedVersion, "version file must hash the deployed companion");
        }
        assert.equal(await managerWithContext.readCompanionVersion(), expectedVersion);

        const restoreRes = await managerWithContext.restore();
        assert.equal(restoreRes.restored, true);
        for (const directory of deployed) {
            await assert.rejects(() => readFile(join(directory, "autonom.bundle.js")));
            await assert.rejects(() => readFile(join(directory, "autonom.sessions.css")));
            await assert.rejects(() => readFile(join(directory, "autonom.version.json")));
        }
    } finally {
        await env.close();
    }
});

test("computeProductChecksum calculates unpadded Base64 SHA-256 (43 chars) matching Devin Desktop IntegrityService", () => {
    const testBuffer = Buffer.from("console.log('test module content');", "utf8");
    const checksum = computeProductChecksum(testBuffer);

    // Exact length of unpadded Base64 SHA-256 (32 bytes = 44 base64 chars with 1 trailing '=') -> stripped to 43 chars
    assert.equal(checksum.length, 43);
    assert.equal(checksum.endsWith("="), false);

    // Verify against known mathematical digest
    const expected = require("node:crypto").createHash("sha256").update(testBuffer).digest("base64").replace(/=+$/, "");
    assert.equal(checksum, expected);

    // Verify string input handling
    assert.equal(computeProductChecksum("console.log('test module content');"), expected);
});

test("PatchManager synchronizes product.json checksums in-place on ensurePatched and restores on rollback", async () => {
    const env = await fixture({ sessions: true, workbench: true });
    try {
        const manager = new PatchManager(env.directory);
        const productJsonPath = join(env.directory, "product.json");

        const origSessionsContent = await readFile(env.bundlePath);
        const origWorkbenchContent = await readFile(env.workbenchBundlePath);

        const origSessionsChecksum = computeProductChecksum(origSessionsContent);
        const origWorkbenchChecksum = computeProductChecksum(origWorkbenchContent);

        // Populate initial mock product.json with original pristine checksums
        const initialProduct = {
            nameShort: "Devin",
            nameLong: "Devin",
            checksums: {
                "vs/sessions/sessions.desktop.main.js": origSessionsChecksum,
                "vs/workbench/windsurf-chat-client/index.js": origWorkbenchChecksum,
                "vs/base/parts/sandbox/electron-browser/preload.js": "someUnmodifiedPreloadHash12345678901234567",
            },
        };
        await writePrivateFile(productJsonPath, JSON.stringify(initialProduct, null, "\t") + "\n");

        // Apply patches
        const patchResult = await manager.ensurePatched();
        assert.equal(patchResult.applied, true);

        // Read patched files and compute actual checksums
        const patchedSessionsContent = await readFile(env.bundlePath);
        const patchedWorkbenchContent = await readFile(env.workbenchBundlePath);
        const patchedSessionsChecksum = computeProductChecksum(patchedSessionsContent);
        const patchedWorkbenchChecksum = computeProductChecksum(patchedWorkbenchContent);

        // Verify product.json was updated in-place with patched checksums
        const updatedProduct = JSON.parse(await readFile(productJsonPath, "utf8"));
        assert.equal(updatedProduct.checksums["vs/sessions/sessions.desktop.main.js"], patchedSessionsChecksum);
        assert.equal(updatedProduct.checksums["vs/workbench/windsurf-chat-client/index.js"], patchedWorkbenchChecksum);
        // Unmodified entries are preserved
        assert.equal(updatedProduct.checksums["vs/base/parts/sandbox/electron-browser/preload.js"], "someUnmodifiedPreloadHash12345678901234567");

        // Rollback
        const rollbackResult = await manager.restoreOriginal();
        assert.equal(rollbackResult.restored, true);

        // Verify product.json checksums restored back to pristine values bit-for-bit
        const restoredProduct = JSON.parse(await readFile(productJsonPath, "utf8"));
        assert.equal(restoredProduct.checksums["vs/sessions/sessions.desktop.main.js"], origSessionsChecksum);
        assert.equal(restoredProduct.checksums["vs/workbench/windsurf-chat-client/index.js"], origWorkbenchChecksum);
        assert.equal(restoredProduct.checksums["vs/base/parts/sandbox/electron-browser/preload.js"], "someUnmodifiedPreloadHash12345678901234567");
    } finally {
        await env.close();
    }
});

test("PatchManager falls back to pristine backup in sessionsDir when bundle directory is unwritable", async () => {
    const env = await fixture({ sessions: true, workbench: true });
    const wbDir = join(env.directory, "out", "vs", "workbench", "windsurf-chat-client");
    try {
        const manager = new PatchManager(env.directory);
        const origWorkbenchContent = await readFile(env.workbenchBundlePath, "utf8");
        const origWorkbenchSha = computeSha256(origWorkbenchContent);

        // Make workbench bundle directory read-only (0555), but leave bundle file writable (0644)
        // Mimicking root:root 0755 directory ownership with user:user 0644 file ownership
        await chmod(wbDir, 0o555);

        // resolveBackupPath should detect that wbDir is unwritable and point to sessionsDir
        const resolvedBackup = manager.resolveBackupPath(WORKBENCH_BUNDLE_CONFIG, env.workbenchBundlePath);
        const expectedFallback = join(manager.getSessionsDir(), "windsurf-chat-client.index.js.autonom.orig");
        assert.equal(resolvedBackup, expectedFallback);

        // ensurePatched must succeed by saving backup to sessionsDir
        const patchResult = await manager.ensurePatched();
        assert.equal(patchResult.applied, true);

        // Verify fallback backup exists in sessionsDir with exact SHA-256 match
        assert.equal(await readFile(expectedFallback, "utf8"), origWorkbenchContent);
        assert.equal(computeSha256(await readFile(expectedFallback)), origWorkbenchSha);

        // Rollback must restore workbench bundle from fallback backup
        const restoreResult = await manager.restoreOriginal();
        assert.equal(restoreResult.restored, true);

        const restoredWb = await readFile(env.workbenchBundlePath, "utf8");
        assert.equal(computeSha256(restoredWb), origWorkbenchSha);
        assert.equal(restoredWb, origWorkbenchContent);
    } finally {
        await chmod(wbDir, 0o755);
        await env.close();
    }
});

test("PatchManager BOOTSTRAP_HEADER resolves companion assets and hot-patches via the version file", () => {
    assert.ok(BOOTSTRAP_HEADER.includes("globalThis._VSCODE_FILE_ROOT"));
    assert.ok(BOOTSTRAP_HEADER.includes('new URL("vs/sessions/autonom.bundle.js",globalThis._VSCODE_FILE_ROOT).href'));
    assert.ok(BOOTSTRAP_HEADER.includes('new URL("vs/sessions/autonom.sessions.css",globalThis._VSCODE_FILE_ROOT).href'));
    // Fallback literal path remains present for environments without _VSCODE_FILE_ROOT.
    assert.ok(BOOTSTRAP_HEADER.includes('"./autonom.bundle.js"'));
    // Hot patch: the bootstrap polls the deployed version file and re-imports the companion.
    assert.ok(BOOTSTRAP_HEADER.includes('new URL("vs/sessions/autonom.version.json",globalThis._VSCODE_FILE_ROOT).href'));
    assert.ok(BOOTSTRAP_HEADER.includes("data.version!==loadedVersion"));
    // Provider switch mirrors Devin's native Agent/Editor switch markup.
    assert.ok(BOOTSTRAP_HEADER.includes("agent-editor-switch"));
    assert.ok(BOOTSTRAP_HEADER.includes("switch-container"));
    assert.ok(BOOTSTRAP_HEADER.includes("switch-segment"));
    assert.ok(BOOTSTRAP_HEADER.includes("segment-label"));
    // React-owned slot and CSS-driven provider isolation.
    assert.ok(BOOTSTRAP_HEADER.includes("sidebarSlot"));
    assert.ok(BOOTSTRAP_HEADER.includes("data-autonom-provider"));
    assert.ok(BOOTSTRAP_HEADER.includes('html[data-autonom-provider=autonom] [data-autonom-slot=sidebar]~*'));
    assert.ok(BOOTSTRAP_HEADER.includes(MARKER_V4));
    assert.equal(BOOTSTRAP_HEADER.includes("innerHTML"), false, "BOOTSTRAP_HEADER must not contain innerHTML");
    assert.equal(BOOTSTRAP_HEADER.includes("outerHTML"), false, "BOOTSTRAP_HEADER must not contain outerHTML");
    assert.equal(BOOTSTRAP_HEADER.includes("document.write"), false, "BOOTSTRAP_HEADER must not contain document.write");
});

test("PatchManager ensurePatched and restore return per-bundle status in result.bundles", async () => {
    const env = await fixture({ sessions: true, workbench: true });
    try {
        const manager = new PatchManager(env.directory);

        const patchRes = await manager.ensurePatched();
        assert.equal(patchRes.applied, true);
        assert.ok(Array.isArray(patchRes.bundles));
        assert.equal(patchRes.bundles.length, 2);

        const wbPatch = patchRes.bundles.find((b) => b.id === "workbench");
        const sessPatch = patchRes.bundles.find((b) => b.id === "sessions");
        assert.ok(wbPatch);
        assert.equal(wbPatch.applied, true);
        assert.ok(sessPatch);
        assert.equal(sessPatch.applied, true);

        // Redundant patch call
        const redundantRes = await manager.ensurePatched();
        assert.equal(redundantRes.applied, false);
        assert.equal(redundantRes.alreadyPatched, true);
        assert.ok(Array.isArray(redundantRes.bundles));
        for (const b of redundantRes.bundles) {
            assert.equal(b.alreadyPatched, true);
        }

        // Restore
        const restoreRes = await manager.restoreOriginal();
        assert.equal(restoreRes.restored, true);
        assert.ok(Array.isArray(restoreRes.bundles));
        assert.equal(restoreRes.bundles.length, 2);
        for (const b of restoreRes.bundles) {
            assert.equal(b.restored, true);
        }
    } finally {
        await env.close();
    }
});

test("PatchManager getProductJsonPath isolates to specified appRoot and never falls back to host product.json", async () => {
    const env = await fixture();
    try {
        const manager = new PatchManager(env.directory);
        const expected = join(env.directory, "product.json");
        assert.equal(manager.getProductJsonPath(), expected);
        assert.notEqual(manager.getProductJsonPath(), "/usr/share/devin-desktop/resources/app/product.json");
    } finally {
        await env.close();
    }
});

test("PatchManager getProductJsonPath resolves mock context with asAbsolutePath to fixture product.json", async () => {
    const env = await fixture();
    try {
        const mockContext = {
            asAbsolutePath: (rel: string) => join(env.directory, rel),
        };
        const manager = new PatchManager(mockContext);
        assert.equal(manager.getProductJsonPath(), join(env.directory, "product.json"));
        assert.notEqual(manager.getProductJsonPath(), "/usr/share/devin-desktop/resources/app/product.json");
    } finally {
        await env.close();
    }
});

test("PatchManager syncProductChecksums is a safe no-op when product.json is absent in appRoot", async () => {
    const env = await fixture();
    try {
        const manager = new PatchManager(env.directory);
        const fakeMap = new Map<string, Buffer>([["vs/sessions/sessions.desktop.main.js", Buffer.from("patched test content")]]);
        // Should not throw and should not create product.json or touch /usr/share/...
        manager.syncProductChecksums(fakeMap);
        await assert.rejects(() => readFile(join(env.directory, "product.json")));
    } finally {
        await env.close();
    }
});

