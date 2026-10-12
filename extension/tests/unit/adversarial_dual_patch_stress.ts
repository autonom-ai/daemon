import {
    BOOTSTRAP_HEADER,
    computeSha256,
    PatchManager,
    MARKER_V1,
    MARKER_P1,
    MARKER_P2,
    MARKER_P3,
} from "../../source/host/patch";
import { writePrivateFile } from "../../source/host/files";

import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

function createRealisticWorkbenchBundle(): string {
    const part1 = `"use strict";(self.webpackChunk=self.webpackChunk||[]).push([[123],{456:(e,t,n)=>{var tX=n(789);var rNj=n(101);var rNG=n(102);var rNR=n(103);var rDI=n(104);var eU={current:null};var tg="spaces-sidebar-anchor";var iqs=n(105);var ewt=n(106);`;
    const hook1 = `function renderNewSessionBtn(isActive){return (0,tX.jsx)(rNj,{children:(0,tX.jsxs)(rNG,{ariaLabel:"New session",isActive:isActive,variant:"nav",elem:null}))};`;
    const hook2 = `function renderSpacesRail(){return {children:[tg,(0,tX.jsx)(rNR,{children:(0,tX.jsx)(rDI,{ref:eU,className:"static z-auto bg-transparent",label:"Spaces",children:"Spaces"})})]};};`;
    const hook3 = `function renderViewport(){return {children:[(0,tX.jsx)(iqs,{}),(0,tX.jsx)(ewt,{})]};};`;
    const part2 = `e.exports={renderNewSessionBtn,renderSpacesRail,renderViewport};}}]);`;
    return part1 + hook1 + hook2 + hook3 + part2;
}

function createRealisticSessionsBundle(): string {
    const part1 = `"use strict";define(["require","exports"],function(e,t){var _=e("jsxRuntime");var nft=e("slot1");var ift=e("btn1");var eft=e("slot2");var YY1=e("btn2");var Tm={current:null};var jY="spaces-anchor";var vsu=e("comp1");var WTr=e("comp2");`;
    const hook1 = `function renderNewSessionBtn(a){return (0,_.jsx)(nft,{children:(0,_.jsxs)(ift,{ariaLabel:"New session",isActive:a,variant:"nav",elem:null}))};`;
    const hook2 = `function renderSpacesRail(){return {children:[jY,(0,_.jsx)(eft,{children:(0,_.jsx)(YY1,{ref:Tm,className:"static z-auto bg-transparent",label:"Spaces",children:"Spaces"})})]};};`;
    const hook3 = `function renderViewport(){return {children:[(0,_.jsx)(vsu,{}),(0,_.jsx)(WTr,{})]};};`;
    const part2 = `return {renderNewSessionBtn,renderSpacesRail,renderViewport};});`;
    return part1 + hook1 + hook2 + hook3 + part2;
}

function createRealisticSessionsHtml(): string {
    return `<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'nonce-test'; style-src 'self' 'unsafe-inline'; connect-src 'self' https:;" />
    <title>Devin Desktop Sessions</title>
</head>
<body>
    <div id="root"></div>
</body>
</html>`;
}

interface DualFixture {
    directory: string;
    wbBundlePath: string;
    wbBackupPath: string;
    sessBundlePath: string;
    sessBackupPath: string;
    htmlPath: string;
    htmlBackupPath: string;
    mockContext: any;
    close: () => Promise<void>;
}

async function createDualFixture(): Promise<DualFixture> {
    const directory = await mkdtemp(join(tmpdir(), "autonom-dual-stress-"));

    const wbDir = join(directory, "out", "vs", "workbench", "windsurf-chat-client");
    const wbBundlePath = join(wbDir, "index.js");
    const wbBackupPath = `${wbBundlePath}.autonom.orig`;

    const sessDir = join(directory, "out", "vs", "sessions");
    const sessBundlePath = join(sessDir, "sessions.desktop.main.js");
    const sessBackupPath = `${sessBundlePath}.autonom.orig`;

    const htmlDir = join(sessDir, "electron-browser");
    const htmlPath = join(htmlDir, "sessions.html");
    const htmlBackupPath = `${htmlPath}.autonom.orig`;

    // Create realistic fixture bundles
    await writePrivateFile(wbBundlePath, createRealisticWorkbenchBundle());
    await writePrivateFile(sessBundlePath, createRealisticSessionsBundle());
    await writePrivateFile(htmlPath, createRealisticSessionsHtml());

    // Create mock companion assets
    const companionDir = join(directory, "dist", "commandCenter");
    await writePrivateFile(join(companionDir, "autonom.bundle.js"), "export function init(){}");
    await writePrivateFile(join(companionDir, "autonom.sessions.css"), "/* autonom css */");

    const mockContext = {
        asAbsolutePath: (rel: string) => join(directory, rel),
    };

    return {
        directory,
        wbBundlePath,
        wbBackupPath,
        sessBundlePath,
        sessBackupPath,
        htmlPath,
        htmlBackupPath,
        mockContext,
        close: () => rm(directory, { recursive: true, force: true }),
    };
}

// ---------------------------------------------------------------------------
// ADVERSARIAL STRESS TEST SUITE
// ---------------------------------------------------------------------------

test("ADVERSARIAL STRESS 1: Execute 50 consecutive patch and rollback cycles on realistic dual-target bundles with bit-for-bit SHA-256 assertion", async () => {
    const env = await createDualFixture();
    try {
        const manager = new PatchManager(env.directory);

        // Record pristine content and pristine SHA-256 hashes
        const pristineWbBuffer = await readFile(env.wbBundlePath);
        const pristineWbSha = computeSha256(pristineWbBuffer);

        const pristineSessBuffer = await readFile(env.sessBundlePath);
        const pristineSessSha = computeSha256(pristineSessBuffer);

        const pristineHtmlBuffer = await readFile(env.htmlPath);
        const pristineHtmlSha = computeSha256(pristineHtmlBuffer);

        assert.ok(pristineWbSha.length === 64);
        assert.ok(pristineSessSha.length === 64);
        assert.ok(pristineHtmlSha.length === 64);

        for (let cycle = 1; cycle <= 50; cycle++) {
            // STEP A: Apply dual-target patch
            const patchRes = await manager.ensurePatched();
            assert.equal(patchRes.applied, true, `Cycle ${cycle}: ensurePatched failed with ${patchRes.error}`);
            assert.equal(await manager.isPatched(), true, `Cycle ${cycle}: isPatched returned false after patching`);

            // Verify both bundle files now contain their respective surgical hooks
            const patchedWb = await readFile(env.wbBundlePath, "utf8");
            assert.ok(patchedWb.includes("wrapNewSession?.(tX)"), `Cycle ${cycle}: Workbench missing JSX injection`);
            assert.ok(patchedWb.includes(MARKER_V1), `Cycle ${cycle}: Workbench missing MARKER_V1`);
            assert.ok(patchedWb.includes(MARKER_P1), `Cycle ${cycle}: Workbench missing MARKER_P1`);
            assert.ok(patchedWb.includes(MARKER_P2), `Cycle ${cycle}: Workbench missing MARKER_P2`);
            assert.ok(patchedWb.includes(MARKER_P3), `Cycle ${cycle}: Workbench missing MARKER_P3`);

            const patchedSess = await readFile(env.sessBundlePath, "utf8");
            assert.ok(patchedSess.includes("wrapNewSession?.(_)"), `Cycle ${cycle}: Sessions missing JSX injection`);
            assert.ok(patchedSess.includes(MARKER_V1), `Cycle ${cycle}: Sessions missing MARKER_V1`);
            assert.ok(patchedSess.includes(MARKER_P1), `Cycle ${cycle}: Sessions missing MARKER_P1`);
            assert.ok(patchedSess.includes(MARKER_P2), `Cycle ${cycle}: Sessions missing MARKER_P2`);
            assert.ok(patchedSess.includes(MARKER_P3), `Cycle ${cycle}: Sessions missing MARKER_P3`);

            // Verify companion HTML contains injected styles and CSP
            const patchedHtml = await readFile(env.htmlPath, "utf8");
            assert.ok(patchedHtml.includes("autonom.sessions.css"), `Cycle ${cycle}: HTML missing css link`);
            assert.ok(patchedHtml.includes("connect-src http://127.0.0.1:*"), `Cycle ${cycle}: HTML missing CSP`);

            // STEP B: Execute rollback
            const restoreRes = await manager.restoreOriginal();
            assert.equal(restoreRes.restored, true, `Cycle ${cycle}: restoreOriginal failed with ${restoreRes.error}`);
            assert.equal(await manager.isPatched(), false, `Cycle ${cycle}: isPatched returned true after rollback`);

            // STEP C: Strict bit-for-bit SHA-256 and Buffer equality assertions
            const restoredWbBuffer = await readFile(env.wbBundlePath);
            const restoredWbSha = computeSha256(restoredWbBuffer);
            assert.equal(
                restoredWbSha,
                pristineWbSha,
                `Cycle ${cycle}: Workbench SHA-256 mismatch! Pristine: ${pristineWbSha}, Restored: ${restoredWbSha}`
            );
            assert.equal(
                Buffer.compare(pristineWbBuffer, restoredWbBuffer),
                0,
                `Cycle ${cycle}: Workbench buffer byte-level mismatch`
            );

            const restoredSessBuffer = await readFile(env.sessBundlePath);
            const restoredSessSha = computeSha256(restoredSessBuffer);
            assert.equal(
                restoredSessSha,
                pristineSessSha,
                `Cycle ${cycle}: Sessions SHA-256 mismatch! Pristine: ${pristineSessSha}, Restored: ${restoredSessSha}`
            );
            assert.equal(
                Buffer.compare(pristineSessBuffer, restoredSessBuffer),
                0,
                `Cycle ${cycle}: Sessions buffer byte-level mismatch`
            );

            const restoredHtmlBuffer = await readFile(env.htmlPath);
            const restoredHtmlSha = computeSha256(restoredHtmlBuffer);
            assert.equal(
                restoredHtmlSha,
                pristineHtmlSha,
                `Cycle ${cycle}: HTML SHA-256 mismatch! Pristine: ${pristineHtmlSha}, Restored: ${restoredHtmlSha}`
            );
            assert.equal(
                Buffer.compare(pristineHtmlBuffer, restoredHtmlBuffer),
                0,
                `Cycle ${cycle}: HTML buffer byte-level mismatch`
            );
        }
    } finally {
        await env.close();
    }
});

test("ADVERSARIAL STRESS 2: Read-only permissions (0444) on both bundles: checkStatus and ensurePatched handle EACCES gracefully without throwing and provide actionable remediation", async () => {
    const env = await createDualFixture();
    try {
        // Set both bundles to read-only 0444
        await chmod(env.wbBundlePath, 0o444);
        await chmod(env.sessBundlePath, 0o444);

        const manager = new PatchManager(env.directory);

        // 1. checkStatus() verification
        const status = await manager.checkStatus();
        assert.equal(status.available, true, "Bundles should be available");
        assert.equal(status.writable, false, "Must detect unwritable status");
        assert.equal(status.patched, false, "Must not be patched");
        assert.ok(status.error, "Must surface actionable error string");
        assert.ok(
            status.error.includes("Write permission denied"),
            `Expected 'Write permission denied' in: ${status.error}`
        );
        assert.ok(
            status.error.includes("sudo chown -R $USER"),
            `Expected remediation command 'sudo chown -R $USER' in: ${status.error}`
        );

        // Verify bundle-level detail
        assert.ok(Array.isArray(status.bundles));
        assert.equal(status.bundles.length, 2);
        for (const b of status.bundles) {
            assert.equal(b.writable, false, `Bundle ${b.id} must have writable=false`);
            assert.ok(b.error?.includes("Write permission denied"));
        }

        // 2. ensurePatched() verification: must NOT throw uncaught exception
        const patchResult = await manager.ensurePatched();
        assert.equal(patchResult.applied, false, "Must not apply patch when bundles are unwritable");
        assert.equal(patchResult.writable, false, "Must report writable=false");
        assert.ok(patchResult.error, "Must return error message");
        assert.ok(
            patchResult.error.includes("Write permission denied"),
            `Expected 'Write permission denied' in: ${patchResult.error}`
        );
        assert.ok(
            patchResult.error.includes("sudo chown -R $USER"),
            `Expected remediation command 'sudo chown -R $USER' in: ${patchResult.error}`
        );

        // Verify files remain untouched and no unverified backups were created
        assert.equal(await manager.isPatched(), false);
        await chmod(env.wbBundlePath, 0o644);
        await chmod(env.sessBundlePath, 0o644);
    } finally {
        await env.close();
    }
});

test("ADVERSARIAL STRESS 3: Asymmetric read-only permissions (Workbench 0444, Sessions 0644): checkStatus and ensurePatched handle partial writability safely", async () => {
    const env = await createDualFixture();
    try {
        // Workbench is read-only (mimicking root ownership on Linux)
        await chmod(env.wbBundlePath, 0o444);
        // Sessions is normal writable (mimicking user ownership)
        await chmod(env.sessBundlePath, 0o644);

        const manager = new PatchManager(env.directory);

        // checkStatus() should indicate overall unwritable and identify workbench as the failing bundle
        const status = await manager.checkStatus();
        assert.equal(status.writable, false, "Overall writable must be false when any bundle is unwritable");
        assert.ok(status.error?.includes("Write permission denied"), "Error must name write permission failure");
        assert.ok(status.error?.includes("windsurf-chat-client"), "Error must name the failing workbench bundle");

        const wbStatus = status.bundles?.find((b) => b.id === "workbench");
        const sessStatus = status.bundles?.find((b) => b.id === "sessions");
        assert.equal(wbStatus?.writable, false);
        assert.equal(sessStatus?.writable, true);

        // ensurePatched() should patch the writable sessions bundle while leaving unwritable workbench safe
        const patchResult = await manager.ensurePatched();
        assert.equal(patchResult.applied, true);

        // Verify sessions was patched
        const patchedSess = await readFile(env.sessBundlePath, "utf8");
        assert.ok(patchedSess.includes("wrapNewSession?.(_)"));

        // Verify workbench was NOT modified and remains pristine
        const wbContent = await readFile(env.wbBundlePath, "utf8");
        assert.equal(wbContent.includes(MARKER_V1), false, "Unwritable workbench must NOT be modified");

        await chmod(env.wbBundlePath, 0o644);
    } finally {
        await env.close();
    }
});

test("ADVERSARIAL STRESS 4: Trusted Types Audit across codebase and bundled outputs: zero raw innerHTML, outerHTML, or document.write assignments", async () => {
    // 1. Audit BOOTSTRAP_HEADER in patch.ts
    assert.equal(BOOTSTRAP_HEADER.includes("innerHTML"), false, "BOOTSTRAP_HEADER must have zero innerHTML");
    assert.equal(BOOTSTRAP_HEADER.includes("outerHTML"), false, "BOOTSTRAP_HEADER must have zero outerHTML");
    assert.equal(BOOTSTRAP_HEADER.includes("document.write"), false, "BOOTSTRAP_HEADER must have zero document.write");

    // 2. Audit compiled companion bundle dist/commandCenter/autonom.bundle.js
    const companionBundlePath = join(__dirname, "..", "..", "dist", "commandCenter", "autonom.bundle.js");
    const companionBundleCode = await readFile(companionBundlePath, "utf8");

    // Scan for raw assignment patterns: .innerHTML =, .outerHTML =, document.write(
    const innerHtmlRegex = /\.innerHTML\s*=/;
    const outerHtmlRegex = /\.outerHTML\s*=/;
    const docWriteRegex = /document\.write\s*\(/;

    assert.equal(
        innerHtmlRegex.test(companionBundleCode),
        false,
        "dist/commandCenter/autonom.bundle.js must not contain .innerHTML assignments"
    );
    assert.equal(
        outerHtmlRegex.test(companionBundleCode),
        false,
        "dist/commandCenter/autonom.bundle.js must not contain .outerHTML assignments"
    );
    assert.equal(
        docWriteRegex.test(companionBundleCode),
        false,
        "dist/commandCenter/autonom.bundle.js must not contain document.write calls"
    );

    // 3. Audit source commandCenter files
    const cmdCenterSrcPath = join(__dirname, "..", "..", "source", "commandCenter", "index.ts");
    const cmdCenterCode = await readFile(cmdCenterSrcPath, "utf8");

    assert.equal(
        innerHtmlRegex.test(cmdCenterCode),
        false,
        "source/commandCenter/index.ts must not contain .innerHTML assignments"
    );
    assert.equal(
        outerHtmlRegex.test(cmdCenterCode),
        false,
        "source/commandCenter/index.ts must not contain .outerHTML assignments"
    );
    assert.equal(
        docWriteRegex.test(cmdCenterCode),
        false,
        "source/commandCenter/index.ts must not contain document.write calls"
    );

    // 4. Audit actual patched bundle output
    const env = await createDualFixture();
    try {
        const manager = new PatchManager(env.directory);
        await manager.ensurePatched();

        const patchedWb = await readFile(env.wbBundlePath, "utf8");
        const patchedSess = await readFile(env.sessBundlePath, "utf8");

        assert.equal(innerHtmlRegex.test(patchedWb), false, "Patched workbench must not introduce .innerHTML =");
        assert.equal(outerHtmlRegex.test(patchedWb), false, "Patched workbench must not introduce .outerHTML =");
        assert.equal(docWriteRegex.test(patchedWb), false, "Patched workbench must not introduce document.write");

        assert.equal(innerHtmlRegex.test(patchedSess), false, "Patched sessions must not introduce .innerHTML =");
        assert.equal(outerHtmlRegex.test(patchedSess), false, "Patched sessions must not introduce .outerHTML =");
        assert.equal(docWriteRegex.test(patchedSess), false, "Patched sessions must not introduce document.write");
    } finally {
        await env.close();
    }
});

test("ADVERSARIAL STRESS 5: Idempotence stress: 20 rapid redundant ensurePatched() and 20 redundant restore() calls preserve state deterministically", async () => {
    const env = await createDualFixture();
    try {
        const manager = new PatchManager(env.directory);
        const pristineWb = await readFile(env.wbBundlePath);
        const pristineSess = await readFile(env.sessBundlePath);
        const pristineWbSha = computeSha256(pristineWb);
        const pristineSessSha = computeSha256(pristineSess);

        // 1. Initial patch
        const res1 = await manager.ensurePatched();
        assert.equal(res1.applied, true);

        const contentWbAfterFirst = await readFile(env.wbBundlePath, "utf8");
        const contentSessAfterFirst = await readFile(env.sessBundlePath, "utf8");

        // 2. 20 redundant patch calls must all report alreadyPatched and not mutate files
        for (let i = 0; i < 20; i++) {
            const redundant = await manager.ensurePatched();
            assert.equal(redundant.applied, false, `Redundant patch ${i} should have applied=false`);
            assert.equal(redundant.alreadyPatched, true, `Redundant patch ${i} should have alreadyPatched=true`);

            const currentWb = await readFile(env.wbBundlePath, "utf8");
            const currentSess = await readFile(env.sessBundlePath, "utf8");
            assert.equal(currentWb, contentWbAfterFirst, `Redundant patch ${i} altered workbench content!`);
            assert.equal(currentSess, contentSessAfterFirst, `Redundant patch ${i} altered sessions content!`);
        }

        // 3. Rollback
        const restoreRes = await manager.restoreOriginal();
        assert.equal(restoreRes.restored, true);
        assert.equal(computeSha256(await readFile(env.wbBundlePath)), pristineWbSha);
        assert.equal(computeSha256(await readFile(env.sessBundlePath)), pristineSessSha);

        // 4. 20 redundant restore calls must all succeed safely without crashing or corrupting
        for (let i = 0; i < 20; i++) {
            const redundantRestore = await manager.restoreOriginal();
            assert.equal(redundantRestore.restored, true, `Redundant restore ${i} failed`);
            assert.equal(computeSha256(await readFile(env.wbBundlePath)), pristineWbSha);
            assert.equal(computeSha256(await readFile(env.sessBundlePath)), pristineSessSha);
            assert.equal(await manager.isPatched(), false);
        }
    } finally {
        await env.close();
    }
});
