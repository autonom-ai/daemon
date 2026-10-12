import { BOOTSTRAP_HEADER, computeSha256, PatchManager } from "../../source/host/patch";
import { writePrivateFile } from "../../source/host/files";

import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const SESSIONS_HOOK_SLOT = `_.jsx)(nft,{children:(0,_.jsxs)(ift,{ariaLabel:"New session",isActive:a,variant:"nav",elem`;
const WORKBENCH_HOOK_SLOT = `tX.jsx)(rNj,{children:(0,tX.jsxs)(rNG,{ariaLabel:"New session",isActive:a,variant:"nav",elem`;

function createMockBundle(hook = SESSIONS_HOOK_SLOT): string {
    return `"use strict";define(["require","exports"],function(e,t){var a=true;return (0,${hook}:null}))});`;
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

        // Verify dynamic import is guarded with catch handler
        assert.ok(patchedContent.includes('import("./autonom.bundle.js")'));
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

test("PatchManager deployCompanion copies assets to sessions directory and cleans them up on restore", async () => {
    const env = await fixture({ sessions: true, workbench: true });
    try {
        const manager = new PatchManager(env.directory);
        const sessionsDir = manager.getSessionsDir();
        const wbDir = join(env.directory, "out", "vs", "workbench", "windsurf-chat-client");

        // Simulate compiled companion assets in a mock extension directory
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

        const destBundle = join(sessionsDir, "autonom.bundle.js");
        const destCss = join(sessionsDir, "autonom.sessions.css");
        const wbDestBundle = join(wbDir, "autonom.bundle.js");

        assert.equal(await readFile(destBundle, "utf8"), "export function init() {}");
        assert.equal(await readFile(destCss, "utf8"), ".provider-toggle { color: red; }");
        assert.equal(await readFile(wbDestBundle, "utf8"), "export function init() {}");

        // Verify restore cleans up companion files
        const restoreRes = await managerWithContext.restore();
        assert.equal(restoreRes.restored, true);
        await assert.rejects(() => readFile(destBundle));
        await assert.rejects(() => readFile(destCss));
        await assert.rejects(() => readFile(wbDestBundle));
    } finally {
        await env.close();
    }
});
