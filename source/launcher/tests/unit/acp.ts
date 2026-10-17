import { ACP_AGENT_ID, acpRegistryPath, acpSettingsPath, ensureAcpAgent } from "../../acp";

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

async function directory(): Promise<string>
{
    return mkdtemp(join(tmpdir(), "autonom-acp-"));
}

async function command(root: string): Promise<string>
{
    const path = join(root, "autonom-acp");
    await writeFile(path, "#!/bin/sh\n");
    return path;
}

test("the agent is registered and enabled when no files exist", async () =>
{
    const root = await directory();
    try
    {
        const registryPath = join(root, "acp", "registry.json");
        const settingsPath = join(root, "Devin", "User", "settings.json");
        await ensureAcpAgent({ command: await command(root), args: ["--config", "/tmp/config.yml"],
            registryPath, settingsPath });

        const registry = JSON.parse(await readFile(registryPath, "utf8"));
        assert.equal(registry.version, "1.0.0");
        assert.equal(registry.agents.length, 1);
        const agent = registry.agents[0];
        assert.equal(agent.id, ACP_AGENT_ID);
        const platform = Object.keys(agent.distribution.binary)[0]!;
        assert.equal(agent.distribution.binary[platform].args[0], "--config");

        const settings = JSON.parse(await readFile(settingsPath, "utf8"));
        assert.equal(settings["devin.acp.enabledAgents"][ACP_AGENT_ID], true);
        assert.equal(settings["windsurf.acp.enabledAgents"][ACP_AGENT_ID], true);
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});

test("a stale Autonom entry is replaced without dropping other agents", async () =>
{
    const root = await directory();
    try
    {
        const registryPath = join(root, "registry.json");
        const settingsPath = join(root, "settings.json");
        await writeFile(registryPath, JSON.stringify({
            version: "1.0.0",
            agents: [
                { id: "devin-cli", name: "Devin Local" },
                { id: ACP_AGENT_ID, name: "Stale", distribution: { binary: { "linux-x86_64": { cmd: "/old/acp" } } } },
            ],
        }));
        await writeFile(settingsPath, JSON.stringify({
            "devin.acp.enabledAgents": { "devin-cli": true, [ACP_AGENT_ID]: false },
            "other": { "key": 1 },
        }));

        const binary = await command(root);
        await ensureAcpAgent({ command: binary, registryPath, settingsPath });

        const registry = JSON.parse(await readFile(registryPath, "utf8"));
        assert.deepEqual(registry.agents.map((agent: { id: string }) => agent.id), ["devin-cli", ACP_AGENT_ID]);
        assert.equal(registry.agents[1].distribution.binary["linux-x86_64"].cmd, binary);

        const settings = JSON.parse(await readFile(settingsPath, "utf8"));
        assert.equal(settings["devin.acp.enabledAgents"]["devin-cli"], true);
        assert.equal(settings["devin.acp.enabledAgents"][ACP_AGENT_ID], true);
        assert.equal(settings["windsurf.acp.enabledAgents"][ACP_AGENT_ID], true);
        assert.deepEqual(settings.other, { key: 1 });
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});

test("settings comments and trailing commas are tolerated", async () =>
{
    const root = await directory();
    try
    {
        const settingsPath = join(root, "settings.json");
        await writeFile(settingsPath, `{
            // user note https://example.com
            "devin.acp.enabledAgents": {
                "devin-cli": true,
            },
            /* block */
            "windsurf.acp.enabledAgents": {},
        }`);
        await ensureAcpAgent({ command: await command(root), registryPath: join(root, "registry.json"), settingsPath });
        const settings = JSON.parse(await readFile(settingsPath, "utf8"));
        assert.equal(settings["devin.acp.enabledAgents"]["devin-cli"], true);
        assert.equal(settings["devin.acp.enabledAgents"][ACP_AGENT_ID], true);
        assert.equal(settings["windsurf.acp.enabledAgents"][ACP_AGENT_ID], true);
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});

test("an already-correct installation is left untouched", async () =>
{
    const root = await directory();
    try
    {
        const registryPath = join(root, "registry.json");
        const settingsPath = join(root, "settings.json");
        const binary = await command(root);
        await ensureAcpAgent({ command: binary, registryPath, settingsPath });
        const registrySource = await readFile(registryPath);
        const settingsSource = await readFile(settingsPath);
        await ensureAcpAgent({ command: binary, registryPath, settingsPath });
        assert.deepEqual(await readFile(registryPath), registrySource);
        assert.deepEqual(await readFile(settingsPath), settingsSource);
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});

test("a missing agent binary is rejected before any file is written", async () =>
{
    const root = await directory();
    try
    {
        const registryPath = join(root, "registry.json");
        const settingsPath = join(root, "settings.json");
        await assert.rejects(
            ensureAcpAgent({ command: join(root, "missing-acp"), registryPath, settingsPath }),
            /binary is missing/);
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});

test("default paths point at the Desktop profile and Windsurf ACP registry", () =>
{
    assert.equal(acpRegistryPath(), join(homedir(), ".windsurf", "acp", "registry.json"));
    assert.ok(acpSettingsPath().endsWith(join("Devin", "User", "settings.json")));
});
