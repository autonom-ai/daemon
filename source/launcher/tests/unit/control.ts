import type { CdpClient } from "../../cdp";
import { startControlSocket } from "../../control";

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";

const WORKBENCH = "vscode-file://vscode-app/opt/devin/resources/app/out/vs/code/electron-browser/workbench/workbench.html";

function fakeCdp(detached: string[] = []): CdpClient
{
    return {
        async targets(): Promise<unknown>
        {
            return [
                { id: "page-1", type: "page", url: WORKBENCH },
                { id: "worker-1", type: "worker", url: "" },
            ];
        },
        async attach(targetId: string): Promise<unknown>
        {
            return {
                targetId,
                evaluate: async (expression: string) => `evaluated: ${expression}`,
                request: async () => ({ data: Buffer.from("png").toString("base64") }),
                detach: async () =>
                {
                    detached.push(targetId);
                },
            };
        },
    } as unknown as CdpClient;
}

function exchange(socketPath: string, message: unknown): Promise<any>
{
    return new Promise((resolve_, reject) =>
    {
        const socket = createConnection(socketPath);
        let buffer = "";
        socket.setEncoding("utf8");
        socket.on("connect", () =>
        {
            socket.write(`${JSON.stringify(message)}\n`);
        });
        socket.on("data", (chunk) =>
        {
            buffer += chunk;
            const end = buffer.indexOf("\n");
            if (end < 0)
                return;
            socket.end();
            resolve_(JSON.parse(buffer.slice(0, end)));
        });
        socket.on("error", reject);
    });
}

async function socketPath(): Promise<string>
{
    return join(await mkdtemp(join(tmpdir(), "autonom-control-")), "launcher.sock");
}

test("the control socket serves status, targets, and eval for a live launcher", async () =>
{
    const path = await socketPath();
    const detached: string[] = [];
    const control = await startControlSocket(path, {
        cdp: fakeCdp(detached),
        workbenchUrl: WORKBENCH,
        status: async () => ({ windows: [] }),
        hot: async () => ({ ok: true }),
        detach: async () => ({ ok: true }),
    });
    try
    {
        assert.equal((await stat(path)).mode & 0o777, 0o600);
        assert.deepEqual(await exchange(path, { action: "status" }), { result: { windows: [] } });
        assert.equal((await exchange(path, { action: "targets" })).result.length, 2);
        assert.deepEqual(await exchange(path, { action: "eval", target: "page-1", expression: "1+1" }),
            { result: "evaluated: 1+1" });
        assert.deepEqual(detached, ["page-1"]);
        assert.deepEqual(await exchange(path, { action: "nonsense" }), { error: "Unknown control action: nonsense" });
    }
    finally
    {
        await control.close();
    }
});

test("a non-socket control path is never overwritten", async () =>
{
    const path = await socketPath();
    try
    {
        await writeFile(path, "unrelated file");
        await assert.rejects(startControlSocket(path, {
            cdp: fakeCdp(),
            workbenchUrl: WORKBENCH,
            status: async () => ({}),
            hot: async () => ({}),
            detach: async () => ({}),
        }), /non-socket file/);
        assert.equal(await readFile(path, "utf8"), "unrelated file");
    }
    finally
    {
        await rm(dirname(path), { recursive: true, force: true });
    }
});

test("a second launcher cannot take over a live control socket", async () =>
{
    const path = await socketPath();
    const context = {
        cdp: fakeCdp(),
        workbenchUrl: WORKBENCH,
        status: async () => ({}),
        hot: async () => ({}),
        detach: async () => ({}),
    };
    const control = await startControlSocket(path, context);
    try
    {
        await assert.rejects(startControlSocket(path, context), /already listening/);
    }
    finally
    {
        await control.close();
    }
    const replacement = await startControlSocket(path, context);
    await replacement.close();
});
