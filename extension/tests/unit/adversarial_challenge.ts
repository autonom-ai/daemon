import { BOOTSTRAP_HEADER, PatchManager } from "../../source/host/patch";
import { writePrivateFile } from "../../source/host/files";

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const VENDOR_HOOK_SLOT = '_.jsx)(nft,{children:(0,_.jsxs)(ift,{ariaLabel:"New session",isActive:a,variant:"nav",elem';
const SPACES_HOOK_SLOT = 'children:[jY,(0,_.jsx)(eft,{children:(0,_.jsx)(YY1,{ref:Tm,className:"static z-auto bg-transparent",label:"Spaces"';
const SPACES_HOOK_TAIL = 'Sv(null)}})]})})})},bsu="session-repo-filter"';
const CENTER_HOOK_SLOT = 'children:[(0,_.jsx)(vsu,{}),(0,_.jsx)(WTr,{})]';

function sha256(data: string | Buffer): string {
    return createHash("sha256").update(data).digest("hex");
}

function createComplexMockBundle(): string {
    return `"use strict";
define(["require","exports"],function(e,t){
    var a=true;
    var x = (0,${VENDOR_HOOK_SLOT}:null}));
    var y = { ${SPACES_HOOK_SLOT}: true } };
    var tail = '${SPACES_HOOK_TAIL}';
    var z = { ${CENTER_HOOK_SLOT} };
    return { x: x, y: y, z: z, tail: tail };
});`;
}

function createMockHtml(): string {
    return `<!DOCTYPE html>
<html>
<head>
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; connect-src http://localhost:*;">
    <title>Devin Desktop Sessions</title>
</head>
<body>
    <div id="root"></div>
</body>
</html>`;
}

async function fixture(): Promise<{
    directory: string;
    sessionsDir: string;
    bundlePath: string;
    backupPath: string;
    htmlPath: string;
    htmlBackupPath: string;
    close: () => Promise<void>;
}> {
    const directory = await mkdtemp(join(tmpdir(), "autonom-challenger-stress-"));
    const sessionsDir = join(directory, "out", "vs", "sessions");
    const bundlePath = join(sessionsDir, "sessions.desktop.main.js");
    const backupPath = `${bundlePath}.autonom.orig`;
    const htmlPath = join(sessionsDir, "electron-browser", "sessions.html");
    const htmlBackupPath = `${htmlPath}.autonom.orig`;

    await writePrivateFile(bundlePath, createComplexMockBundle());
    await writePrivateFile(htmlPath, createMockHtml());

    return {
        directory,
        sessionsDir,
        bundlePath,
        backupPath,
        htmlPath,
        htmlBackupPath,
        close: () => rm(directory, { recursive: true, force: true }),
    };
}

test("Challenger Stress 1: PatchManager with absent companion bundle reports bootstrap-only deployment honestly", async () => {
    const env = await fixture();
    try {
        // Point manager to a directory with NO dist/commandCenter companion assets
        const manager = new PatchManager(env.directory);
        const result = await manager.ensurePatched();

        assert.equal(result.applied, true, "Patch should apply even when companion bundle is not on disk");

        // Explicitly ensure companion bundle is absent on disk
        const deployedBundle = join(env.sessionsDir, "autonom.bundle.js");
        await rm(deployedBundle, { force: true });
        await assert.rejects(() => readFile(deployedBundle));

        // Read patched bundle and verify self-contained bootstrap
        const patchedContent = await readFile(env.bundlePath, "utf8");
        assert.ok(patchedContent.includes("/*__AUTONOM_PATCH_V4__*/"));
        assert.ok(patchedContent.includes("globalThis.__autonom="));
        assert.ok(patchedContent.includes('"./autonom.bundle.js"'));

        // Save bootstrap header to a standalone .mjs file in temporary directory and evaluate via dynamic import
        const mjsPath = join(env.directory, "test_eval.mjs");
        const evalCode = `
delete globalThis.__autonom;
${patchedContent.slice(0, patchedContent.indexOf("define(["))}
`;
        await writeFile(mjsPath, evalCode, "utf8");

        // Dynamic import evaluates the module; dynamic import("./autonom.bundle.js") will reject,
        // but .catch(...) must catch it cleanly without crashing or throwing
        await import("file://" + mjsPath);

        const autonomObj = (globalThis as any).__autonom;
        assert.ok(autonomObj, "globalThis.__autonom must be defined by synchronous inline micro-hook");
        assert.equal(autonomObj.isAutonomActive(), true, "Default mode should be active autonom");
        assert.equal(typeof autonomObj.wrapNewSession, "function", "wrapNewSession fallback must be present");
        assert.equal(typeof autonomObj.subscribe, "function", "subscribe must be present");
    } finally {
        await env.close();
    }
});

test("Challenger Stress 2: PatchManager with corrupted companion bundle evaluates safely via defensive dynamic loader", async () => {
    const env = await fixture();
    try {
        // Provide mockContext with a syntax-invalid companion bundle
        const mockContext = {
            asAbsolutePath: (rel: string) => join(env.directory, rel),
        };
        const srcBundle = join(env.directory, "dist", "commandCenter", "autonom.bundle.js");
        const srcCss = join(env.directory, "dist", "commandCenter", "autonom.sessions.css");
        await writePrivateFile(srcBundle, ">>>SYNTAX ERROR CORRUPTED BUNDLE<<<");
        await writePrivateFile(srcCss, "/* invalid css */ {{{{");

        const manager = new PatchManager(mockContext);
        (manager as any).sessionsDir = env.sessionsDir;
        (manager as any).mainJsPath = env.bundlePath;
        (manager as any).backupPath = env.backupPath;

        const result = await manager.ensurePatched();
        assert.equal(result.applied, true);

        // Verify corrupted bundle was copied
        const destBundle = join(env.sessionsDir, "autonom.bundle.js");
        assert.equal(await readFile(destBundle, "utf8"), ">>>SYNTAX ERROR CORRUPTED BUNDLE<<<");

        // Now test module evaluation:
        // Even when ./autonom.bundle.js throws a SyntaxError on dynamic import,
        // the catch handler in BOOTSTRAP_HEADER absorbs the error safely
        const mjsPath = join(env.sessionsDir, "corrupted_eval_test.mjs");
        const patchedContent = await readFile(env.bundlePath, "utf8");
        const evalCode = `
delete globalThis.__autonom;
${patchedContent.slice(0, patchedContent.indexOf("define(["))}
`;
        await writeFile(mjsPath, evalCode, "utf8");

        await import("file://" + mjsPath);

        const autonomObj = (globalThis as any).__autonom;
        assert.ok(autonomObj, "globalThis.__autonom must survive corrupted companion bundle");
        assert.equal(autonomObj.isAutonomActive(), true);
    } finally {
        await env.close();
    }
});

test("Challenger Stress 3: deployCompanion reports missing companion assets instead of claiming success", async () => {
    const env = await fixture();
    try {
        const mockContext = {
            asAbsolutePath: (rel: string) => join(env.directory, rel),
        };
        const srcBundle = join(env.directory, "dist", "commandCenter", "autonom.bundle.js");
        await writePrivateFile(srcBundle, "valid code");

        const manager = new PatchManager(mockContext);
        (manager as any).sessionsDir = env.sessionsDir;
        (manager as any).mainJsPath = env.bundlePath;
        (manager as any).backupPath = env.backupPath;

        const result = await manager.ensurePatched();
        assert.equal(result.applied, false);
        assert.match(result.error ?? "", /Build the Autonom companion bundle and stylesheet/);
        assert.equal(await manager.isPatched(), false);
    } finally {
        await env.close();
    }
});

test("Challenger Stress 4: 50 consecutive patch and rollback cycles guarantee bit-for-bit SHA-256 restoration", async () => {
    const env = await fixture();
    try {
        const manager = new PatchManager(env.directory);
        const pristineBuffer = await readFile(env.bundlePath);
        const pristineSha = sha256(pristineBuffer);

        for (let cycle = 1; cycle <= 50; cycle++) {
            // 1. Apply patch
            const patchRes = await manager.ensurePatched();
            assert.equal(patchRes.applied, true, `Cycle ${cycle}: patch application failed`);
            assert.equal(await manager.isPatched(), true, `Cycle ${cycle}: isPatched returned false after patch`);

            // 2. Rollback
            const restoreRes = await manager.restoreOriginal();
            assert.equal(restoreRes.restored, true, `Cycle ${cycle}: rollback failed`);
            assert.equal(await manager.isPatched(), false, `Cycle ${cycle}: isPatched returned true after restore`);

            // 3. Bit-for-bit check
            const restoredBuffer = await readFile(env.bundlePath);
            const restoredSha = sha256(restoredBuffer);
            assert.equal(
                restoredSha,
                pristineSha,
                `Cycle ${cycle}: SHA-256 mismatch! Expected ${pristineSha}, got ${restoredSha}`
            );
            assert.equal(
                Buffer.compare(pristineBuffer, restoredBuffer),
                0,
                `Cycle ${cycle}: Buffer byte-for-byte mismatch`
            );
        }
    } finally {
        await env.close();
    }
});

test("Challenger Stress 5: Multi-cycle HTML patch and rollback maintains bit-for-bit integrity", async () => {
    const env = await fixture();
    try {
        const manager = new PatchManager(env.directory);
        const pristineHtmlBuffer = await readFile(env.htmlPath);
        const pristineHtmlSha = sha256(pristineHtmlBuffer);

        for (let cycle = 1; cycle <= 20; cycle++) {
            await manager.ensurePatched();
            const patchedHtml = await readFile(env.htmlPath, "utf8");
            assert.ok(patchedHtml.includes("autonom.sessions.css"), `Cycle ${cycle}: HTML missing css link`);
            assert.ok(patchedHtml.includes("connect-src http://127.0.0.1:*"), `Cycle ${cycle}: HTML missing CSP patch`);

            await manager.restoreOriginal();
            const restoredHtmlBuffer = await readFile(env.htmlPath);
            assert.equal(
                sha256(restoredHtmlBuffer),
                pristineHtmlSha,
                `Cycle ${cycle}: HTML SHA-256 mismatch after rollback`
            );
        }
    } finally {
        await env.close();
    }
});






test("Challenger Stress 11: BOOTSTRAP_HEADER micro-hook provider toggle fails to update when localStorage throws SecurityError", async () => {
    const originalLocalStorage = (globalThis as any).localStorage;
    const mjsPath = join(tmpdir(), `bootstrap_sec_test_${Date.now()}.mjs`);
    try {
        (globalThis as any).localStorage = {
            getItem() {
                throw new Error("SecurityError: blocked");
            },
            setItem() {
                throw new Error("SecurityError: blocked");
            },
        };

        const evalCode = `
delete globalThis.__autonom;
${BOOTSTRAP_HEADER}
`;
        await writeFile(mjsPath, evalCode, "utf8");
        await import("file://" + mjsPath);

        const autonomObj = (globalThis as any).__autonom;
        assert.ok(autonomObj);
        assert.equal(autonomObj.isAutonomActive(), true);

        // Setting provider to devin-cloud
        autonomObj.provider = "devin-cloud";
        assert.equal(autonomObj.isAutonomActive(), false);
    } finally {
        await rm(mjsPath, { force: true });
        (globalThis as any).localStorage = originalLocalStorage;
    }
});

