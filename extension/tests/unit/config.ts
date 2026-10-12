import { configureKey, configurationState, readSettings, saveDaemon, savePolicy, validateSettings } from "../../source/host/config";
import { readPrivateFile, revision, writePrivateFile } from "../../source/host/files";
import { readCapability } from "../../source/host/client";
import { installWorkspace, mergeHooks } from "../../source/host/setup";

import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";

async function fixture(): Promise<{ directory: string; config: string; close: () => Promise<void> }>
{
    const directory = await mkdtemp(join(tmpdir(), "autonom-extension-"));
    const config = join(directory, "config.yml");
    await writePrivateFile(config, "devinCommand: devin\nrouter:\n  type: openrouter\n  key: private-test-key\n");
    return { directory, config, close: () => rm(directory, { recursive: true, force: true }) };
}

test("Settings are normalized and invalid persisted inputs are rejected", () =>
{
    const settings = readSettings({ get: () => undefined }, "/repo/extension");
    assert.equal(settings.port, 8080);
    assert.equal(settings.permissionMode, "auto");
    assert.equal(settings.rootDirectory, "/repo");
    assert.throws(() => validateSettings({ ...settings, port: -1 }));
    assert.throws(() => validateSettings({ ...settings, rootDirectory: "relative" }));
    assert.deepEqual(validateSettings(settings), settings);
});

test("Sidebar configuration never contains router credentials", async () =>
{
    const temporary = await fixture();
    try
    {
        const state = await configurationState(temporary.directory, temporary.config);
        assert.equal(state.routerConfigured, true);
        assert.equal(JSON.stringify(state).includes("private-test-key"), false);
    }
    finally
    {
        await temporary.close();
    }
});

test("Saving daemon settings preserves the router and refuses secret fields", async () =>
{
    const temporary = await fixture();
    try
    {
        await saveDaemon(temporary.config, { offlineStartAfter: "2h", compactOnResume: true });
        const saved = await readFile(temporary.config, "utf8");
        assert.ok(saved.includes("private-test-key"));
        assert.ok(saved.includes("offlineStartAfter: 2h"));
        await assert.rejects(saveDaemon(temporary.config, { router: { key: "injected" } }));
        await configureKey(temporary.config, "new-private-test-key");
        assert.ok((await readFile(temporary.config, "utf8")).includes("new-private-test-key"));
    }
    finally
    {
        await temporary.close();
    }
});

test("Policy saves detect conflicting disk edits and invalid screen rules", async () =>
{
    const temporary = await fixture();
    try
    {
        const path = join(temporary.directory, ".devin", "policy.yml");
        await writePrivateFile(path, "rules:\n  - action: allow\n");
        const version = revision(await readPrivateFile(path));
        await writePrivateFile(path, "rules:\n  - action: deny\n");
        await assert.rejects(savePolicy(temporary.directory, "rules: []\n", version), /changed on disk/);
        await assert.rejects(savePolicy(temporary.directory, "rules:\n  - action: screen\n",
            revision(await readPrivateFile(path))), /require models/);
    }
    finally
    {
        await temporary.close();
    }
});

test("Configuration writes and capability reads reject symlinks and unsafe permissions", async () =>
{
    const temporary = await fixture();
    try
    {
        const alias = join(temporary.directory, "alias.yml");
        await symlink(temporary.config, alias);
        await assert.rejects(writePrivateFile(alias, "bad"));
        await assert.rejects(readPrivateFile(alias));
        const capability = join(temporary.directory, "client.token");
        await writePrivateFile(capability, "a".repeat(64));
        assert.equal(await readCapability(capability), "a".repeat(64));
        await chmod(capability, 0o644);
        await assert.rejects(readCapability(capability), /private/);
    }
    finally
    {
        await temporary.close();
    }
});

test("Hook merging removes old Autonom forwarding but keeps unrelated hooks", () =>
{
    const existing = { PreToolUse: [{ matcher: "", hooks: [
        { command: "echo keep" }, { command: "curl http://localhost/api/hooks/pre-tool-use" },
    ] }], Stop: [{ hooks: [{ command: "echo done" }] }] };
    const merged = mergeHooks(existing, { PreToolUse: [{ hooks: [{ command: "python3 source/coord/hook.py" }] }] });
    const text = JSON.stringify(merged);
    assert.ok(text.includes("echo keep"));
    assert.ok(text.includes("echo done"));
    assert.ok(!text.includes("curl"));
    assert.equal(JSON.stringify(existing).includes("curl"), true);
});

test("Old unauthenticated curl hooks do not count as a ready workspace", async () =>
{
    const temporary = await fixture();
    try
    {
        await writePrivateFile(join(temporary.directory, ".devin", "hooks.v1.json"),
            '{"PreToolUse":[{"hooks":[{"command":"curl http://localhost/api/hooks/pre-tool-use"}]}]}');
        await writePrivateFile(join(temporary.directory, ".devin", "mcp_config.json"),
            '{"mcpServers":{"autonom-coord":{"args":["/repo/source/coord/server.py"]}}}');
        assert.equal((await configurationState(temporary.directory, temporary.config)).installed, false);
    }
    finally
    {
        await temporary.close();
    }
});

test("Workspace setup is idempotent and preserves MCP servers and workspace policy", async () =>
{
    const temporary = await fixture();
    try
    {
        const workspace = join(temporary.directory, "workspace");
        await writePrivateFile(join(workspace, ".devin", "policy.yml"), "rules:\n  - action: deny\n");
        await writePrivateFile(join(workspace, ".devin", "mcp_config.json"), '{"mcpServers":{"existing":{"command":"keep"}}}');
        const settings = readSettings({ get: () => undefined }, resolve("."));
        settings.rootDirectory = resolve("..");
        settings.configFile = temporary.config;
        await installWorkspace(workspace, settings);
        assert.equal((await configurationState(workspace, temporary.config)).installed, true);
        const first = await readFile(join(workspace, ".devin", "hooks.v1.json"), "utf8");
        await installWorkspace(workspace, settings);
        assert.equal(await readFile(join(workspace, ".devin", "hooks.v1.json"), "utf8"), first);
        assert.equal(await readFile(join(workspace, ".devin", "policy.yml"), "utf8"), "rules:\n  - action: deny\n");
        assert.ok((await readFile(join(workspace, ".devin", "mcp_config.json"), "utf8")).includes('"existing"'));
    }
    finally
    {
        await temporary.close();
    }
});
