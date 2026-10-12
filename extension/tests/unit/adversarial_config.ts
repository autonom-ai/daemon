import { saveDaemon, savePolicy, validateSettings } from "../../source/host/config";
import { readPrivateFile, revision, writePrivateFile } from "../../source/host/files";
import { modelOptions } from "../../source/webview/dom";

import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

async function fixture(): Promise<{ directory: string; config: string; close: () => Promise<void> }>
{
    const directory = await mkdtemp(join(tmpdir(), "autonom-challenger-"));
    const config = join(directory, "config.yml");
    await writePrivateFile(config, "devinCommand: devin\nrouter:\n  type: openrouter\n  key: private-screen-key\n");
    return { directory, config, close: () => rm(directory, { recursive: true, force: true }) };
}

test("validateSettings: rejects negative, zero, out-of-range, and floating-point ports", () =>
{
    const base = {
        rootDirectory: "/abs/path",
        configFile: "/abs/config.yml",
        port: 8080,
        defaultModel: "swe-2-medium",
        permissionMode: "auto",
        pollIntervalMs: 1000,
        notifyPings: true,
    };

    assert.throws(() => validateSettings({ ...base, port: -1 }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, port: 0 }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, port: 65536 }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, port: 100000 }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, port: 8080.5 }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, port: NaN }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, port: "8080" }), /Settings require/);

    // Valid boundaries
    assert.equal(validateSettings({ ...base, port: 1 }).port, 1);
    assert.equal(validateSettings({ ...base, port: 65535 }).port, 65535);
});

test("validateSettings: rejects poll intervals below 500ms and above 10000ms", () =>
{
    const base = {
        rootDirectory: "/abs/path",
        configFile: "/abs/config.yml",
        port: 8080,
        defaultModel: "swe-2-medium",
        permissionMode: "auto",
        pollIntervalMs: 1000,
        notifyPings: true,
    };

    assert.throws(() => validateSettings({ ...base, pollIntervalMs: 0 }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, pollIntervalMs: 499 }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, pollIntervalMs: -100 }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, pollIntervalMs: 10001 }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, pollIntervalMs: 99999 }), /Settings require/);

    // Valid boundaries
    assert.equal(validateSettings({ ...base, pollIntervalMs: 500 }).pollIntervalMs, 500);
    assert.equal(validateSettings({ ...base, pollIntervalMs: 10000 }).pollIntervalMs, 10000);
});

test("validateSettings: rejects relative paths, unsupported permission modes, and missing models", () =>
{
    const base = {
        rootDirectory: "/abs/path",
        configFile: "/abs/config.yml",
        port: 8080,
        defaultModel: "swe-2-medium",
        permissionMode: "auto",
        pollIntervalMs: 1000,
        notifyPings: true,
    };

    assert.throws(() => validateSettings({ ...base, rootDirectory: "relative/path" }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, configFile: "./config.yml" }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, rootDirectory: "" }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, configFile: "" }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, permissionMode: "root" }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, permissionMode: "admin" }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, permissionMode: "" }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, defaultModel: "" }), /Settings require/);
    assert.throws(() => validateSettings({ ...base, notifyPings: "yes" }), /Settings require/);
});

test("saveDaemon: rejects invalid durations, malformed compaction thresholds, and non-whitelisted fields", async () =>
{
    const temporary = await fixture();
    try
    {
        // Invalid duration formats
        await assert.rejects(saveDaemon(temporary.config, { executionTimeout: "-30m" }), /Durations must be positive/);
        await assert.rejects(saveDaemon(temporary.config, { executionTimeout: "0m" }), /Durations must be positive/);
        await assert.rejects(saveDaemon(temporary.config, { executionTimeout: "30x" }), /Durations must be positive/);
        await assert.rejects(saveDaemon(temporary.config, { executionTimeout: "invalid" }), /Durations must be positive/);
        await assert.rejects(saveDaemon(temporary.config, { offlineStartAfter: "" }), /Daemon settings require/);
        await assert.rejects(saveDaemon(temporary.config, { offlineStartAfter: "1000000000m" }), /Durations must be positive/);

        // Malformed compaction thresholds
        await assert.rejects(saveDaemon(temporary.config, { compactionThresholds: "1" }), /two or three increasing/);
        await assert.rejects(saveDaemon(temporary.config, { compactionThresholds: "1,2,3,4" }), /two or three increasing/);
        await assert.rejects(saveDaemon(temporary.config, { compactionThresholds: "3,2,1" }), /two or three increasing/);
        await assert.rejects(saveDaemon(temporary.config, { compactionThresholds: "-1,2,3" }), /two or three increasing/);
        await assert.rejects(saveDaemon(temporary.config, { compactionThresholds: "a,b,c" }), /two or three increasing/);

        // Unsupported or forbidden secret fields
        await assert.rejects(saveDaemon(temporary.config, { router: { key: "steal" } }), /Unsupported daemon setting/);
        await assert.rejects(saveDaemon(temporary.config, { evilField: "payload" }), /Unsupported daemon setting/);

        // Valid values succeed
        await saveDaemon(temporary.config, {
            executionTimeout: "45m",
            offlineStartAfter: "2h",
            offlineCompactAfter: "30m",
            compactionThresholds: "10,20,30",
            compactOnResume: true,
        });
    }
    finally
    {
        await temporary.close();
    }
});

test("savePolicy: rejects invalid actions, missing models/questions on screen, and payload limits", async () =>
{
    const temporary = await fixture();
    try
    {
        const policyPath = join(temporary.directory, ".devin", "policy.yml");
        await writePrivateFile(policyPath, "rules:\n  - action: allow\n");
        const version = revision(await readPrivateFile(policyPath));

        // Invalid YAML
        await assert.rejects(savePolicy(temporary.directory, "{ bad: yaml: [", version), /Policy must contain/);

        // Missing rules list
        await assert.rejects(savePolicy(temporary.directory, "version: 1\n", version), /rules list/);

        // Invalid rule action
        await assert.rejects(savePolicy(temporary.directory, "rules:\n  - action: bypass_everything\n", version),
            /Every policy rule must have an allow, deny, or screen action/);

        // Screen rule without models or questions
        await assert.rejects(savePolicy(temporary.directory, "rules:\n  - action: screen\n    models: []\n", version),
            /require models and predicate questions/);

        // Policy exceeds size limit (65536 bytes)
        const massivePolicy = "rules:\n  - action: allow\n" + "# comment\n".repeat(7000);
        await assert.rejects(savePolicy(temporary.directory, massivePolicy, version), /size limit/);
    }
    finally
    {
        await temporary.close();
    }
});

test("modelOptions: defaults to swe-2-medium on empty catalog and escapes HTML", () =>
{
    // Empty catalog fallback
    const emptyMarkup = modelOptions([], "");
    assert.ok(emptyMarkup.includes('value="swe-2-medium"'));
    assert.ok(emptyMarkup.includes('selected'));
    assert.ok(emptyMarkup.includes('SWE-2 Medium'));

    // Missing selected model is preserved as prepended option
    const customMarkup = modelOptions([], "custom-custom-model");
    assert.ok(customMarkup.includes('<option value="custom-custom-model" selected>custom-custom-model</option>'));

    // HTML escaping
    const xssMarkup = modelOptions([
        { id: '"><script>alert(1)</script>', label: '"><img src=x onerror=alert(1)>', family: '"><b onmouseover=1>evil</b>' }
    ], "");
    assert.ok(!xssMarkup.includes("<script>"));
    assert.ok(!xssMarkup.includes("<img"));
    assert.ok(!xssMarkup.includes("<b "));
    assert.ok(xssMarkup.includes("&lt;script&gt;"));
    assert.ok(xssMarkup.includes("&lt;img"));
});
