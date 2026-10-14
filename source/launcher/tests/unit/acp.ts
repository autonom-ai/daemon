import { startAcpHost } from "../../acp/host";
import { installAutonomAgent } from "../../acp/registry";
import type { DaemonClient } from "../../client";

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createConnection } from "node:net";
import type { Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

test("Autonom registry uses the launcher adapter and preserves other agents", async () =>
{
    const root = await mkdtemp(join(tmpdir(), "autonom-acp-"));
    try
    {
        const path = join(root, "registry.json");
        const original = '{"version":"1.0.0","agents":[{"id":"other","name":"Other"}]}\n';
        await writeFile(path, original);
        await installAutonomAgent(root, join(root, "acp.sock"), path);
        await installAutonomAgent(root, join(root, "acp.sock"), path);
        const registry = JSON.parse(await readFile(path, "utf8"));
        assert.equal(registry.agents.length, 2);
        assert.equal(registry.agents[0].id, "other");
        assert.equal(registry.agents[1].id, "devin-autonom");
        assert.deepEqual(registry.agents[1].distribution.binary["linux-x86_64"].args,
            [join(root, "source", "launcher", "acp", "server.py"), "--socket", join(root, "acp.sock")]);
        assert.equal((await stat(path)).mode & 0o777, 0o600);
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});

test("Autonom registry install preserves unrelated agents and rejects an externally changed entry", async () =>
{
    const root = await mkdtemp(join(tmpdir(), "autonom-acp-"));
    try
    {
        const path = join(root, "registry.json");
        await writeFile(path, '{"version":"1.0.0","agents":[]}');
        await installAutonomAgent(root, join(root, "acp.sock"), path);
        const registry = JSON.parse(await readFile(path, "utf8"));
        registry.agents.push({ id: "other", name: "Other" });
        await writeFile(path, JSON.stringify(registry));
        await installAutonomAgent(root, join(root, "acp.sock"), path);
        const installed = JSON.parse(await readFile(path, "utf8"));
        assert.deepEqual(installed.agents.map((agent: { id: string }) => agent.id), ["devin-autonom", "other"]);
        installed.agents.find((agent: { id: string }) => agent.id === "devin-autonom").name = "External edit";
        const source = JSON.stringify(installed);
        await writeFile(path, source);
        await assert.rejects(installAutonomAgent(root, join(root, "acp.sock"), path), /changed externally/);
        assert.equal(await readFile(path, "utf8"), source);
    }
    finally
    {
        await rm(root, { force: true, recursive: true });
    }
});

function socketRequest(socket: Socket, message: Record<string, unknown>): Promise<Record<string, unknown>>
{
    return new Promise((resolve_, reject) =>
    {
        let buffer = "";
        socket.setEncoding("utf8");
        socket.on("data", (chunk) =>
        {
            buffer += chunk;
            const end = buffer.indexOf("\n");
            if (end < 0)
                return;
            resolve_(JSON.parse(buffer.slice(0, end)));
        });
        socket.on("error", reject);
        socket.write(`${JSON.stringify(message)}\n`);
    });
}

test("the ACP host brokers only the daemon-owned hook API and stops executions on disconnect", async () =>
{
    const root = await mkdtemp(join(tmpdir(), "autonom-acp-host-"));
    const calls: { path: string; method: string }[] = [];
    const client = {
        async request<Result>(path: string, method = "GET", _body?: unknown): Promise<Result>
        {
            calls.push({ path, method });
            if (path === "/api/acp")
                return { id: "123e4567-e89b-42d3-a456-426614174000" } as Result;
            if (path.endsWith("/stop"))
                return { status: "stopping" } as Result;
            if (path.startsWith("/api/executions/"))
                return { status: "stopped" } as Result;
            return { ok: true } as Result;
        },
    } as unknown as DaemonClient;
    const host = await startAcpHost(client, join(root, "hook", "acp.sock"));
    try
    {
        assert.equal((await stat(host.socketPath)).isSocket(), true);
        assert.equal((await stat(host.socketPath)).mode & 0o777, 0o600);
        const socket = await new Promise<Socket>((resolve_, reject) =>
        {
            const connection = createConnection(host.socketPath);
            connection.on("connect", () => resolve_(connection));
            connection.on("error", reject);
        });

        const started = await socketRequest(socket, { id: "one", action: "request", path: "/api/acp", method: "POST", body: {} });
        assert.equal((started.result as { id: string }).id, "123e4567-e89b-42d3-a456-426614174000");
        const denied = await socketRequest(socket, { id: "two", action: "request", path: "/api/schedules", method: "POST", body: {} });
        assert.match(String(denied.error), /not allowed/);
        const stopped = await socketRequest(socket, {
            id: "three", action: "request", path: "/api/executions/123e4567-e89b-42d3-a456-426614174000/stop", method: "POST",
        });
        assert.equal((stopped.result as { status: string }).status, "stopping");

        socket.destroy();
        await new Promise((resolve_) => setTimeout(resolve_, 200));
        assert.equal(calls.filter((call) => call.path.endsWith("/stop")).length, 2);
        await host.close();
        assert.deepEqual(calls.at(-1), { path: "/api/executions/123e4567-e89b-42d3-a456-426614174000", method: "GET" });
    }
    finally
    {
        await host.close().catch(() => undefined);
        await rm(root, { force: true, recursive: true });
    }
});
