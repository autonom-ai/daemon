import { acpAgentId, acpRegistryIcons, acpRegistryPath, acpSettingsPath, ensureAcpAgent } from "../../../launcher/acp/registry";

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
        assert.equal(agent.id, acpAgentId);
        assert.equal(Object.hasOwn(agent, "icon"), false);
        const platform = Object.keys(agent.distribution.binary)[0]!;
        assert.equal(agent.distribution.binary[platform].args[0], "--config");

        const settings = JSON.parse(await readFile(settingsPath, "utf8"));
        assert.equal(settings["devin.acp.enabledAgents"][acpAgentId], true);
        assert.equal(settings["windsurf.acp.enabledAgents"][acpAgentId], true);
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
                { id: "devin-cli", name: "Devin Local", custom: "untouched" },
                { id: acpAgentId, name: "Stale", icon: "./custom icon.svg", custom: { preserved: true },
                    distribution: { binary: { "linux-x86_64": { cmd: "/old/acp" } } } },
            ],
        }));
        await writeFile(settingsPath, JSON.stringify({
            "devin.acp.enabledAgents": { "devin-cli": true, [acpAgentId]: false },
            "other": { "key": 1 },
        }));

        const binary = await command(root);
        await ensureAcpAgent({ command: binary, registryPath, settingsPath });

        const registry = JSON.parse(await readFile(registryPath, "utf8"));
        assert.deepEqual(registry.agents.map((agent: { id: string }) => agent.id), ["devin-cli", acpAgentId]);
        assert.equal(registry.agents[1].distribution.binary["linux-x86_64"].cmd, binary);
        assert.equal(registry.agents[1].icon, "./custom icon.svg");
        assert.deepEqual(registry.agents[1].custom, { preserved: true });
        assert.equal(registry.agents[0].custom, "untouched");

        const settings = JSON.parse(await readFile(settingsPath, "utf8"));
        assert.equal(settings["devin.acp.enabledAgents"]["devin-cli"], true);
        assert.equal(settings["devin.acp.enabledAgents"][acpAgentId], true);
        assert.equal(settings["windsurf.acp.enabledAgents"][acpAgentId], true);
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
        assert.equal(settings["devin.acp.enabledAgents"][acpAgentId], true);
        assert.equal(settings["windsurf.acp.enabledAgents"][acpAgentId], true);
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});

test("an already-correct installation preserves its custom icon, metadata, ordering and bytes", async () =>
{
    const root = await directory();
    try
    {
        const registryPath = join(root, "registry.json");
        const settingsPath = join(root, "settings.json");
        const binary = await command(root);
        await ensureAcpAgent({ command: binary, registryPath, settingsPath });
        const registry = JSON.parse(await readFile(registryPath, "utf8"));
        const icon = "  https://example.com/user-owned.svg?unchanged=yes  ";
        registry.note = { preserved: true };
        registry.agents[0].icon = icon;
        registry.agents[0].custom = { nested: ["metadata"] };
        registry.agents.unshift({ id: "antigravity", icon: "./antigravity.svg", custom: "preserved" });
        await writeFile(registryPath, `${JSON.stringify(registry, null, 2)}\n`);
        const registrySource = await readFile(registryPath);
        const settingsSource = await readFile(settingsPath);
        await ensureAcpAgent({ command: binary, registryPath, settingsPath });
        assert.deepEqual(await readFile(registryPath), registrySource);
        assert.deepEqual(await readFile(settingsPath), settingsSource);
        const retained = JSON.parse(await readFile(registryPath, "utf8"));
        assert.deepEqual(retained, registry);
        assert.equal(retained.agents[1].icon, icon);
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

test("registry icons map every agent with an icon to its definition", async () =>
{
    const root = await directory();
    try
    {
        const registryPath = join(root, "registry.json");
        await writeFile(registryPath, JSON.stringify({
            version: "1.0.0",
            agents: [
                { id: "devin-cli", name: "Devin Local" },
                { id: "devin-autonom", icon: "data:image/svg+xml;base64,PHN2Zz4=" },
                { id: "other", icon: "   " },
                { id: "https-agent", icon: "https://example.com/icon.svg" },
            ],
        }));
        assert.deepEqual(await acpRegistryIcons(registryPath), {
            "devin-autonom": "data:image/svg+xml;base64,PHN2Zz4=",
            "https-agent": "https://example.com/icon.svg",
        });
        assert.deepEqual(await acpRegistryIcons(join(root, "missing.json")), {});
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
