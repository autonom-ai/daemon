import { BOOTSTRAP_HEADER, PatchManager } from "../../source/host/patch";
import { writePrivateFile } from "../../source/host/files";
import { safeGetStorage, safeSetStorage } from "../../source/webview/storage";
import { init as initCommandCenter } from "../../source/commandCenter/index";

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const VENDOR_HOOK_SLOT = '_.jsx)(nft,{children:(0,_.jsxs)(ift,{ariaLabel:"New session",isActive:a,variant:"nav",elem';
const SPACES_HOOK_SLOT = 'children:[jY,(0,_.jsx)(eft,{children:(0,_.jsx)(YY1,{ref:Tm,className:"static z-auto bg-transparent",label:"Spaces"';
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
    var z = { ${CENTER_HOOK_SLOT} };
    return { x: x, y: y, z: z };
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

test("Challenger Stress 1: PatchManager with absent companion bundle applies cleanly and executes without uncaught errors", async () => {
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
        assert.ok(patchedContent.includes("/*__AUTONOM_PATCH_V1__*/"));
        assert.ok(patchedContent.includes("globalThis.__autonom="));
        assert.ok(patchedContent.includes('import("./autonom.bundle.js")'));

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

test("Challenger Stress 3: deployCompanion tolerates unreadable source companion files without failing ensurePatched", async () => {
    const env = await fixture();
    try {
        const mockContext = {
            asAbsolutePath: (rel: string) => join(env.directory, rel),
        };
        const srcBundle = join(env.directory, "dist", "commandCenter", "autonom.bundle.js");
        // Create an unreadable file with permissions 000
        await writePrivateFile(srcBundle, "valid code");
        await chmod(srcBundle, 0o000);

        const manager = new PatchManager(mockContext);
        (manager as any).sessionsDir = env.sessionsDir;
        (manager as any).mainJsPath = env.bundlePath;
        (manager as any).backupPath = env.backupPath;

        // ensurePatched should not throw when deployCompanion hits EACCES
        const result = await manager.ensurePatched();
        assert.equal(result.applied, true);
        assert.equal(await manager.isPatched(), true);

        // Restore permissions for cleanup
        await chmod(srcBundle, 0o600);
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

test("Challenger Stress 6: safeStorage handles simulated SecurityError on both getItem and setItem", () => {
    const originalLocalStorage = (globalThis as any).localStorage;
    try {
        (globalThis as any).localStorage = {
            getItem() {
                const err = new Error("Blocked by Security policy.");
                err.name = "SecurityError";
                throw err;
            },
            setItem() {
                const err = new Error("Blocked by Security policy.");
                err.name = "SecurityError";
                throw err;
            },
        };

        // Fallback test
        assert.equal(safeGetStorage("test.nonexistent", "fallbackDefault"), "fallbackDefault");

        // Write test
        safeSetStorage("test.key", "persistedInMap");
        assert.equal(safeGetStorage("test.key", "fallbackDefault"), "persistedInMap");

        // Overwrite test
        safeSetStorage("test.key", "updatedValue");
        assert.equal(safeGetStorage("test.key", "fallbackDefault"), "updatedValue");
    } finally {
        (globalThis as any).localStorage = originalLocalStorage;
    }
});

test("Challenger Stress 7: safeStorage handles QuotaExceededError on setItem and updates in-memory map", () => {
    const originalLocalStorage = (globalThis as any).localStorage;
    const store = new Map<string, string>();
    try {
        (globalThis as any).localStorage = {
            getItem(key: string) {
                return store.get(key) ?? null;
            },
            setItem(key: string, _value: string) {
                if (key === "huge.item") {
                    const quotaErr = new Error("The quota has been exceeded.");
                    quotaErr.name = "QuotaExceededError";
                    (quotaErr as any).code = 22;
                    throw quotaErr;
                }
                store.set(key, _value);
            },
        };

        safeSetStorage("normal.item", "smallData");
        assert.equal(safeGetStorage("normal.item", ""), "smallData");

        // Attempt writing item that triggers QuotaExceededError
        safeSetStorage("huge.item", "massiveDataExceedingQuota");
        // Must not throw, and must be retrievable from in-memory fallback
        assert.equal(safeGetStorage("huge.item", "fallback"), "massiveDataExceedingQuota");
    } finally {
        (globalThis as any).localStorage = originalLocalStorage;
    }
});

test("Challenger Stress 8: safeStorage handles throwing property getter on globalThis.localStorage", () => {
    const originalDescriptor = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
    try {
        Object.defineProperty(globalThis, "localStorage", {
            get() {
                const err = new Error("Access denied by sandbox frame.");
                err.name = "SecurityError";
                throw err;
            },
            configurable: true,
        });

        // Reading should not crash
        assert.equal(safeGetStorage("sandbox.key", "sandboxDefault"), "sandboxDefault");

        // Writing should not crash
        safeSetStorage("sandbox.key", "cachedInMemory");
        assert.equal(safeGetStorage("sandbox.key", "sandboxDefault"), "cachedInMemory");
    } finally {
        if (originalDescriptor) {
            Object.defineProperty(globalThis, "localStorage", originalDescriptor);
        } else {
            delete (globalThis as any).localStorage;
        }
    }
});

test("Challenger Stress 9: safeStorage 2,000 rapid operations with chaotic intermittent storage exceptions", () => {
    const originalLocalStorage = (globalThis as any).localStorage;
    let ops = 0;
    try {
        (globalThis as any).localStorage = {
            getItem(_k: string) {
                ops++;
                if (ops % 3 === 0) {
                    const err = new Error("Random SecurityError");
                    err.name = "SecurityError";
                    throw err;
                }
                return null;
            },
            setItem(_k: string, _v: string) {
                ops++;
                if (ops % 5 === 0) {
                    const err = new Error("QuotaExceededError");
                    err.name = "QuotaExceededError";
                    throw err;
                }
                if (ops % 7 === 0) {
                    const err = new Error("Random DOMException");
                    err.name = "DOMException";
                    throw err;
                }
            },
        };

        for (let i = 0; i < 2000; i++) {
            const key = `stress.key.${i % 50}`;
            const val = `value_${i}`;
            safeSetStorage(key, val);
            const retrieved = safeGetStorage(key, "never_fallback");
            assert.equal(retrieved, val, `Mismatch at iteration ${i} for key ${key}`);
        }
    } finally {
        (globalThis as any).localStorage = originalLocalStorage;
    }
});

test("Challenger Stress 10: CommandCenter companion index init() survives failing localStorage and manages provider toggle", () => {
    const originalLocalStorage = (globalThis as any).localStorage;
    try {
        (globalThis as any).localStorage = {
            getItem() {
                throw new Error("SecurityError: blocked");
            },
            setItem() {
                throw new Error("SecurityError: blocked");
            },
        };

        const mockTarget: any = {};
        const state = initCommandCenter(mockTarget);

        assert.equal(mockTarget.__autonom, state);
        assert.equal(state.isAutonomActive(), true, "Should default to true (autonom) on storage error");

        let notified = "";
        const unsub = state.subscribe((provider) => {
            notified = provider;
        });

        state.setProvider("devin-cloud");
        assert.equal(notified, "devin-cloud");
        assert.equal(state.isAutonomActive(), false);

        state.setProvider("autonom");
        assert.equal(notified, "autonom");
        assert.equal(state.isAutonomActive(), true);

        unsub();
        state.setProvider("devin-cloud");
        assert.equal(notified, "autonom", "Subscriber must not be notified after unsub");
    } finally {
        (globalThis as any).localStorage = originalLocalStorage;
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

