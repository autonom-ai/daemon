import {
    connectDebugTransport,
    DESKTOP_COMMIT,
    DESKTOP_VERSION,
    launchDesktop,
    PipeTransport,
    resolveDesktopBinary,
    verifyDesktopBuild,
    workbenchUrl,
} from "../../desktop";

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { PassThrough } from "node:stream";
import { test } from "node:test";
import { promisify } from "node:util";

const REAL_APP_ROOT = "/usr/share/devin-desktop/resources/app";
const execute = promisify(execFile);

function transport(): { transport: PipeTransport; readable: PassThrough; writable: PassThrough }
{
    const readable = new PassThrough();
    const writable = new PassThrough();
    return { transport: new PipeTransport(readable, writable), readable, writable };
}

function messages(transport: PipeTransport): unknown[]
{
    const ret: unknown[] = [];
    transport.onMessage((message) =>
    {
        ret.push(message);
    });
    return ret;
}

test("pipe transport frames NUL-delimited JSON across chunk boundaries", () =>
{
    const { transport: pipe, readable } = transport();
    const received = messages(pipe);
    readable.write(Buffer.from("{\"id\":1,\"result\":{\"a\":"));
    readable.write(Buffer.from("true}}\0{\"id\":2,\"result\":{}}\0"));
    assert.deepEqual(received, [
        { id: 1, result: { a: true } },
        { id: 2, result: {} },
    ]);
});

test("pipe transport sends NUL-delimited JSON and rejects writes after close", () =>
{
    const { transport: pipe, writable } = transport();
    let written = "";
    writable.on("data", (chunk: Buffer) =>
    {
        written += chunk.toString("utf8");
    });
    pipe.send({ id: 1, method: "Target.getTargets", params: {} });
    assert.equal(written, "{\"id\":1,\"method\":\"Target.getTargets\",\"params\":{}}\0");
    pipe.close();
    assert.throws(() => pipe.send({ id: 2 }), /closed/);
});

test("pipe transport closes on malformed or oversized input", () =>
{
    const { transport: pipe, readable } = transport();
    let closed = 0;
    pipe.onClose(() =>
    {
        closed++;
    });
    readable.write(Buffer.from("not json\0"));
    assert.equal(closed, 1);
    readable.write(Buffer.from("{\"id\":3}\0"));
    assert.equal(closed, 1);
});

test("the Desktop command resolves the Electron binary beside a launcher shim", async () =>
{
    const directory = await mkdtemp(join(tmpdir(), "autonom-desktop-"));
    try
    {
        await mkdir(join(directory, "bin"), { recursive: true });
        await writeFile(join(directory, "bin", "devin-desktop"), "#!/usr/bin/env sh\nexec devin-desktop \"$@\"\n");
        await chmod(join(directory, "bin", "devin-desktop"), 0o755);
        await writeFile(join(directory, "devin-desktop"), "binary");
        await chmod(join(directory, "devin-desktop"), 0o755);
        assert.equal(resolveDesktopBinary(join(directory, "bin", "devin-desktop")), join(directory, "devin-desktop"));
        assert.equal(resolveDesktopBinary(join(directory, "devin-desktop")), join(directory, "devin-desktop"));
        await symlink(join(directory, "bin", "devin-desktop"), join(directory, "command"));
        assert.equal(resolveDesktopBinary(join(directory, "command")), join(directory, "devin-desktop"));
        assert.throws(() => resolveDesktopBinary(join(directory, "missing")), /Cannot find/);
    }
    finally
    {
        await rm(directory, { force: true, recursive: true });
    }
});

test("the workbench target URL points at the pinned Desktop build", () =>
{
    assert.equal(workbenchUrl("/opt/devin/resources/app"),
        "vscode-file://vscode-app/opt/devin/resources/app/out/vs/code/electron-browser/workbench/workbench.html");
});

test("an unsupported Desktop build fails closed", async () =>
{
    const appRoot = await mkdtemp(join(tmpdir(), "autonom-app-"));
    try
    {
        await mkdir(join(appRoot, "out/vs/workbench"), { recursive: true });
        await writeFile(join(appRoot, "out/vs/workbench/workbench.desktop.main.js"), "bundle");
        await writeFile(join(appRoot, "product.json"), JSON.stringify({ commit: DESKTOP_COMMIT }));
        await writeFile(join(appRoot, "package.json"), JSON.stringify({ version: "1.127.0" }));
        await assert.rejects(verifyDesktopBuild(appRoot), /Unsupported Devin Desktop build/);
        await writeFile(join(appRoot, "package.json"),
            JSON.stringify({ version: DESKTOP_VERSION, main: "./out/main.js" }));
        await writeFile(join(appRoot, "product.json"), JSON.stringify({ commit: "0000000000000000000000000000000000000000" }));
        await assert.rejects(verifyDesktopBuild(appRoot), /Unsupported Devin Desktop build/);
        await writeFile(join(appRoot, "product.json"), JSON.stringify({ commit: DESKTOP_COMMIT }));
        await assert.rejects(verifyDesktopBuild(appRoot), /pristine build/);
    }
    finally
    {
        await rm(appRoot, { force: true, recursive: true });
    }
});

test("debug mode rejects non-loopback and non-browser WebSocket endpoints", async () =>
{
    for (const address of [
        "ws://localhost:9222/devtools/browser/test",
        "ws://127.0.0.1:9333/devtools/browser/test",
        "ws://127.0.0.1:9222/devtools/page/test",
        "wss://127.0.0.1:9222/devtools/browser/test",
        "ws://user:password@127.0.0.1:9222/devtools/browser/test",
    ])
        await assert.rejects(connectDebugTransport(address, 9222), /non-loopback browser/);
});

test("debug mode refuses an occupied port before spawning Desktop", async () =>
{
    const server = createServer();
    await new Promise<void>((resolve_) => server.listen(0, "127.0.0.1", resolve_));
    const address = server.address();
    assert.ok(address && typeof address !== "string");
    try
    {
        await assert.rejects(launchDesktop({ binary: "/not-an-executable", debugPort: address.port }),
            { code: "EADDRINUSE" });
    }
    finally
    {
        await new Promise<void>((resolve_) => server.close(() => resolve_()));
    }
});

test("the installed Desktop build satisfies the pin or its owning package", { skip: !existsSync(REAL_APP_ROOT) }, async () =>
{
    const identity = await verifyDesktopBuild(REAL_APP_ROOT);
    assert.ok(identity.source === "pin" || identity.source === "package");
});

test("Desktop children run without inherited host or capability variables", async () =>
{
    const directory = await mkdtemp(join(tmpdir(), "autonom-env-"));
    const dump = join(directory, "env.txt");
    const script = join(directory, "dump.sh");
    const names = [
        "ACP_BACKEND",
        "ELECTRON_RUN_AS_NODE",
        "VSCODE_IPC_HOOK",
        "WINDSURF_KEY",
        "AUTONOM_CLIENT_TOKEN",
        "AUTONOM_RUN_TOKEN",
        "AUTONOM_MCP_TOKEN",
        "AUTONOM_RELAY_TOKEN",
        "OPENROUTER_API_KEY",
    ];
    const previous = new Map(names.map((name) => [name, process.env[name]]));
    for (const name of names)
        process.env[name] = "leak";
    try
    {
        await writeFile(script, `#!/bin/sh\nenv > '${dump}'\n`);
        await chmod(script, 0o755);
        const { child, transport } = await launchDesktop({ binary: script });
        await new Promise<void>((resolve_) =>
        {
            child.on("close", resolve_);
        });
        transport.close();
        const environment = await readFile(dump, "utf8");
        assert.match(environment, /^PATH=/m);
        assert.match(environment, /^VSCODE_CWD=/m);
        for (const name of names)
            assert.ok(!environment.includes(`${name}=`), `${name} leaked into the Desktop child`);
    }
    finally
    {
        for (const name of names)
        {
            const value = previous.get(name);
            if (value === undefined)
                delete process.env[name];
            else
                process.env[name] = value;
        }
        await rm(directory, { force: true, recursive: true });
    }
});

test("the launcher rejects an invalid --debug port before touching Desktop", async () =>
{
    const launcher = resolve(__dirname, "../../launcher.js");
    for (const argument of ["--debug=", "--debug=0", "--debug=65536", "--debug=abc"])
    {
        const failure = await execute("node", [launcher, argument])
            .catch((error: unknown) => error) as { code?: number; stdout?: string };
        assert.equal(failure.code, 1);
        assert.match(String(failure.stdout), /must be an integer/);
    }
});
