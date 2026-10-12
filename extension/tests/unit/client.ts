import { DaemonClient } from "../../source/host/client";
import { Controller } from "../../source/host/controller";
import { emptyDaemon } from "../../source/protocol";
import { writePrivateFile } from "../../source/host/files";
import type { HostMessage, Settings } from "../../source/protocol";

import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

async function fixture()
{
    const directory = await mkdtemp(join(tmpdir(), "autonom-client-"));
    const capability = join(directory, "client.token");
    const config = join(directory, "config.yml");
    await writePrivateFile(capability, "a".repeat(64));
    await writePrivateFile(config, "devinCommand: devin\nrouter:\n  key: private-test-key\n");
    const seen: { path: string; token: string; body: string }[] = [];
    const server = createServer(async (request, response) =>
    {
        let body = "";
        for await (const part of request)
            body += String(part);
        const path = request.url || "";
        seen.push({ path, body, token: String(request.headers["x-autonom-client"] || "") });
        response.setHeader("content-type", "application/json");
        if (path === "/api/health")
            response.end(JSON.stringify({ status: "ok", controlFile: capability, configFile: config, pid: 1, workerPid: 2 }));
        else if (path.startsWith("/api/client/state"))
            response.end(JSON.stringify(emptyDaemon()));
        else if (path === "/api/client/models")
            response.end('{"families":[]}');
        else if (path === "/api/error")
            response.writeHead(409).end('{"error":"Session is active"}');
        else
            response.end("{}");
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    assert.ok(address !== null && typeof address !== "string");
    const settings: Settings = { rootDirectory: directory, configFile: config, port: address.port,
        defaultModel: "swe-2-medium", permissionMode: "auto", pollIntervalMs: 1000, notifyPings: true };
    return {
        settings, directory, seen,
        close: async () =>
        {
            server.closeAllConnections();
            await new Promise<void>((resolve) => server.close(() => resolve()));
            await rm(directory, { recursive: true, force: true });
        },
    };
}

test("Client uses only loopback and reads its private token outside the webview", async () =>
{
    const temporary = await fixture();
    try
    {
        const client = new DaemonClient(temporary.settings);
        await Promise.all([client.connect(), client.connect(), client.connect()]);
        assert.equal(temporary.seen.filter((request) => request.path === "/api/health").length, 1);
        await client.request("/api/profiles");
        assert.equal(temporary.seen.at(-1)?.token, "a".repeat(64));
        await assert.rejects(client.request("https://example.com/api"), /Invalid/);
        await assert.rejects(client.request("/api/error"), /Session is active/);
    }
    finally
    {
        await temporary.close();
    }
});

test("Controller never puts credentials in webview state and rejects unmanaged resume", async () =>
{
    const temporary = await fixture();
    try
    {
        const messages: HostMessage[] = [];
        const controller = new Controller(temporary.settings, {
            workspace: () => temporary.directory,
            trusted: () => true,
            send: (message) => messages.push(message),
            confirm: async () => false,
            localAction: async () => undefined,
        });
        await controller.refresh();
        assert.equal(controller.state.connected, true);
        assert.ok(!JSON.stringify(messages).includes("private-test-key"));
        assert.ok(!JSON.stringify(messages).includes("a".repeat(64)));
        await controller.handle({ type: "resume", session: "foreign", prompt: "hello", mode: "auto" });
        const result = messages.at(-1);
        assert.equal(result?.type, "result");
        assert.equal(result?.type === "result" && result.ok, false);
        assert.ok(!temporary.seen.some((request) => request.path.includes("foreign/resume")));
    }
    finally
    {
        await temporary.close();
    }
});

test("Untrusted workspaces do not connect or launch daemon processes", async () =>
{
    const temporary = await fixture();
    try
    {
        const controller = new Controller(temporary.settings, {
            workspace: () => temporary.directory,
            trusted: () => false,
            send: () => undefined,
            confirm: async () => false,
            localAction: async () => undefined,
        });
        await controller.refresh();
        assert.equal(controller.state.connected, false);
        assert.equal(temporary.seen.length, 0);
    }
    finally
    {
        await temporary.close();
    }
});
