import { DaemonClient } from "../../source/host/client";
import type { Settings } from "../../source/protocol";

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";

test("DaemonClient rejects invalid paths without /api/ prefix", async () => {
    const settings: Settings = {
        port: 19999,
        rootDirectory: "/tmp",
        configFile: "/tmp/config.yml",
        defaultModel: "swe-2-medium",
        permissionMode: "bypass",
        pollIntervalMs: 1000,
        notifyPings: true,
    };
    const client = new DaemonClient(settings);
    await assert.rejects(
        client.request("/evil/path"),
        /Invalid Autonom API path/,
    );
    await assert.rejects(
        client.request("/api/test#frag"),
        /Invalid Autonom API path/,
    );
});

test("DaemonClient transmits authenticated loopback request and parses json response", async () => {
    let receivedAuth = "";
    let receivedBody = "";
    let receivedMethod = "";
    const server = createServer((req, res) => {
        receivedAuth = req.headers["x-autonom-client"] as string || "";
        receivedMethod = req.method || "";
        let body = "";
        req.on("data", (chunk) => { body += chunk; });
        req.on("end", () => {
            receivedBody = body;
            res.writeHead(200, { "content-type": "application/json" });
            res.end(JSON.stringify({ ok: true, data: "pong" }));
        });
    });

    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
    const port = (server.address() as any).port;

    try {
        const settings: Settings = {
            port,
            rootDirectory: "/tmp",
            configFile: "/tmp/config.yml",
            defaultModel: "swe-2-medium",
            permissionMode: "bypass",
            pollIntervalMs: 1000,
            notifyPings: true,
        };
        const client = new DaemonClient(settings);
        // Set mock token directly
        (client as any).token = "test-token-12345";

        const res = await client.request<{ ok: boolean; data: string }>("/api/ping", "POST", { hello: "world" });
        assert.equal(res.ok, true);
        assert.equal(res.data, "pong");
        assert.equal(receivedAuth, "test-token-12345");
        assert.equal(receivedMethod, "POST");
        assert.equal(JSON.parse(receivedBody).hello, "world");
    } finally {
        server.close();
    }
});

test("DaemonClient clears token on 403 response", async () => {
    const server = createServer((_req, res) => {
        res.writeHead(403, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "Forbidden capability" }));
    });

    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
    const port = (server.address() as any).port;

    try {
        const settings: Settings = {
            port,
            rootDirectory: "/tmp",
            configFile: "/tmp/config.yml",
            defaultModel: "swe-2-medium",
            permissionMode: "bypass",
            pollIntervalMs: 1000,
            notifyPings: true,
        };
        const client = new DaemonClient(settings);
        (client as any).token = "stale-token";

        await assert.rejects(
            client.request("/api/test"),
            /Forbidden capability/,
        );
        assert.equal((client as any).token, "");
    } finally {
        server.close();
    }
});
