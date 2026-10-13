import { CdpClient, RuntimeCenter, verifyPatchOnlyWarningCase } from "../../source/host/cdp";
import type { CenterContent } from "../../source/commandCenter/content";
import type { RuntimeStatus } from "../../source/commandCenter/native";

import assert from "node:assert/strict";
import crypto from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, TestContext } from "node:test";
import { pathToFileURL } from "node:url";

const PORT = 19882;
const SOCKET = `ws://127.0.0.1:${PORT}/devtools/page/matched`;
const OWNER = "activation-test";
const COMMIT = "fcf7ba39e6150055fad817f8716385b4d320d46d";
const HASH = "da45742ddd56f8d83e38c4c4a57802ffe4b6cc98645a787588eda346d455f22d";
const CONTENT: CenterContent = { enabled: true, items: [], tabs: {}, revision: "first" };
const STATUS: RuntimeStatus = {
    connected: true,
    mode: "autonom",
    enabled: true,
    patchOnlyIntegrityNoticeSuppressed: false,
    revision: "first",
    activeTab: null,
    windowId: 7,
    items: [{ id: "native", label: "Native", path: "/native" }],
};

interface Request
{
    id: number;
    method: string;
    params: Record<string, any>;
}

class MockSocket extends EventTarget
{
    static instances: MockSocket[] = [];
    static handler: (socket: MockSocket, request: Request) => void = () =>
    {
    };
    static autoOpen = true;
    readonly requests: Request[] = [];
    readyState = 0;

    constructor(readonly url: string)
    {
        super();
        MockSocket.instances.push(this);
        if (MockSocket.autoOpen)
        {
            queueMicrotask(() =>
            {
                this.readyState = 1;
                this.dispatchEvent(new Event("open"));
            });
        }
    }

    send(text: string): void
    {
        const request: Request = JSON.parse(text);
        this.requests.push(request);
        MockSocket.handler(this, request);
    }

    close(): void
    {
        this.readyState = 3;
        this.dispatchEvent(new Event("close"));
    }

    receive(text: string): void
    {
        this.dispatchEvent(new MessageEvent("message", { data: text }));
    }

    reply(id: number, result: Record<string, unknown> = {}): void
    {
        this.receive(JSON.stringify({ id, result }));
    }

    event(method: string, params: Record<string, unknown>): void
    {
        this.receive(JSON.stringify({ method, params }));
    }
}

function mockSocket(context: TestContext): void
{
    MockSocket.instances = [];
    MockSocket.autoOpen = true;
    MockSocket.handler = () =>
    {
    };
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, "WebSocket")!;
    Object.defineProperty(globalThis, "WebSocket", { value: MockSocket, configurable: true, writable: true });
    context.after(() =>
    {
        Object.defineProperty(globalThis, "WebSocket", descriptor);
    });
}

async function buildFixture(context: TestContext, trusted = true): Promise<string>
{
    const ret = await mkdtemp(join(tmpdir(), "autonom-cdp-"));
    context.after(async () =>
    {
        await rm(ret, { recursive: true, force: true });
    });
    await mkdir(join(ret, "out/vs/workbench"), { recursive: true });
    await writeFile(join(ret, "product.json"), JSON.stringify({ commit: COMMIT }));
    await writeFile(join(ret, "package.json"), JSON.stringify({ version: "1.126.0" }));
    await writeFile(join(ret, "out/vs/workbench/workbench.desktop.main.js"), "native € fixture");
    if (trusted)
    {
        const original = crypto.createHash;
        context.mock.method(crypto, "createHash", (algorithm: string) =>
        {
            const ret = original(algorithm);
            const update = ret.update.bind(ret);
            context.mock.method(ret, "update", (data: crypto.BinaryLike) =>
            {
                assert.ok(Buffer.isBuffer(data));
                return update(data);
            });
            context.mock.method(ret, "digest", () =>
            {
                return HASH;
            });
            return ret;
        });
    }
    return ret;
}

function workbenchUrl(appRoot: string): string
{
    return "vscode-file://vscode-app"
        + pathToFileURL(join(appRoot, "out/vs/code/electron-browser/workbench/workbench.html")).pathname;
}

function mockTargets(context: TestContext, targets: unknown[]): void
{
    context.mock.method(globalThis, "fetch", async (address: string | URL | Request, options?: RequestInit) =>
    {
        assert.equal(address, `http://127.0.0.1:${PORT}/json/list`);
        assert.equal(options?.redirect, "error");
        assert.ok(options?.signal instanceof AbortSignal);
        return new Response(JSON.stringify(targets), { headers: { "content-type": "application/json" } });
    });
}

function rendererHandler(identities: Record<string, string | null>): void
{
    const owners = new Map<string, string>();
    let breakpoint = 0;
    MockSocket.handler = (socket, request) =>
    {
        const expression: string = request.params.expression ?? "";
        if (request.method === "Debugger.setBreakpointOnFunctionCall")
        {
            socket.reply(request.id, { breakpointId: `capture-${++breakpoint}` });
        }
        else if (request.method === "Runtime.evaluate")
        {
            if (expression.includes("autonomCenter.bridgeIdentity"))
            {
                socket.reply(request.id, { result: { value: identities[socket.url] } });
            }
            else if (expression === "globalThis.__autonomCenter?.owner??null")
            {
                socket.reply(request.id, { result: { value: owners.get(socket.url) ?? null } });
            }
            else if (/props\.get\w+Snapshot$/.test(expression))
            {
                socket.reply(request.id, { result: { objectId: expression, type: "function" } });
            }
            else if (/props\.get\w+Snapshot\(\)$/.test(expression))
            {
                socket.event("Debugger.paused", { hitBreakpoints: ["unrelated"], callFrames: [] });
                socket.event("Debugger.paused", {
                    hitBreakpoints: [`capture-${breakpoint}`],
                    callFrames: [{ callFrameId: `frame-${breakpoint}` }],
                });
                socket.reply(request.id, { result: { type: "object", objectId: "snapshot" } });
            }
            else if (expression.includes("AutonomNative.install"))
            {
                owners.set(socket.url, OWNER);
                socket.reply(request.id, { result: { value: STATUS } });
            }
            else if (expression.includes("runtime.dispose()"))
            {
                owners.delete(socket.url);
                socket.reply(request.id, { result: { type: "undefined" } });
            }
            else if (expression.includes("__autonomCenter.update") || expression.includes("__autonomCenter.status")
                || expression.includes("__autonomCenter.open"))
            {
                socket.reply(request.id, { result: { value: { ...STATUS, unexpectedSecret: "never return this" } } });
            }
            else
            {
                socket.reply(request.id, { result: { value: true } });
            }
        }
        else if (request.method === "Debugger.evaluateOnCallFrame")
        {
            socket.reply(request.id, { result: { value: true } });
        }
        else
        {
            socket.reply(request.id);
        }
    };
}

function methods(socket: MockSocket): string[]
{
    return socket.requests.map((request) => request.method);
}

function assertReleasedGroups(socket: MockSocket): void
{
    const groups = new Set(socket.requests.filter((request) => request.params.objectGroup)
        .map((request) => request.params.objectGroup));
    for (const group of groups)
    {
        assert.equal(socket.requests.filter((request) => request.method === "Runtime.releaseObjectGroup"
            && request.params.objectGroup === group).length, 1);
    }
}

test("CDP rejects non-loopback, wrong-port and credential-bearing socket URLs before connecting", async (context) =>
{
    mockSocket(context);
    for (const address of [
        `ws://localhost:${PORT}/devtools/page/test`,
        `ws://127.0.0.1:${PORT + 1}/devtools/page/test`,
        `ws://127.0.0.1:${PORT}/devtools/browser/test`,
        `wss://127.0.0.1:${PORT}/devtools/page/test`,
        `ws://secret@127.0.0.1:${PORT}/devtools/page/test`,
        `ws://127.0.0.1:${PORT}/devtools/page/test?token=secret`,
        `ws://127.1:${PORT}/devtools/page/test`,
    ])
    {
        await assert.rejects(CdpClient.connect(address, PORT));
    }
    assert.equal(MockSocket.instances.length, 0);
});

test("CDP correlates out-of-order replies and scopes event listeners", async (context) =>
{
    mockSocket(context);
    const client = await CdpClient.connect(SOCKET, PORT);
    const socket = MockSocket.instances[0]!;
    let events = 0;
    const remove = client.on("Debugger.paused", () =>
    {
        events++;
    });
    const first = client.request("First");
    const second = client.request("Second");
    socket.reply(socket.requests[1]!.id, { value: 2 });
    socket.reply(socket.requests[0]!.id, { value: 1 });
    assert.deepEqual(await first, { value: 1 });
    assert.deepEqual(await second, { value: 2 });
    socket.event("Debugger.paused", {});
    remove();
    socket.event("Debugger.paused", {});
    assert.equal(events, 1);
    client.close();
    assert.equal(client.connected, false);
    await assert.rejects(client.request("Closed"), /not connected/);
});

test("CDP rejects every pending request on malformed messages, socket error or close", async (context) =>
{
    mockSocket(context);
    for (const failure of ["malformed", "error", "close", "oversized", "invalid-response", "invalid-event"])
    {
        const client = await CdpClient.connect(SOCKET, PORT);
        const socket = MockSocket.instances.at(-1)!;
        const first = assert.rejects(client.request("First"));
        const second = assert.rejects(client.request("Second"));
        if (failure === "malformed")
            socket.receive("not json");
        else if (failure === "oversized")
            socket.receive(" ".repeat(2 * 1024 * 1024 + 1));
        else if (failure === "invalid-response")
            socket.receive(JSON.stringify({ id: 1, result: null }));
        else if (failure === "invalid-event")
            socket.receive(JSON.stringify({ method: "Debugger.paused", params: [] }));
        else
            socket.dispatchEvent(new Event(failure));
        await Promise.all([first, second]);
        assert.equal(client.connected, false);
    }
});

test("CDP connection and request waits are bounded", async (context) =>
{
    mockSocket(context);
    MockSocket.autoOpen = false;
    await assert.rejects(CdpClient.connect(SOCKET, PORT, 10), /cancelled|Timed out/);
    assert.equal(MockSocket.instances[0]!.readyState, 3);
    MockSocket.autoOpen = true;
    const client = await CdpClient.connect(SOCKET, PORT, 10);
    await assert.rejects(client.request("NeverReplies"), /Timed out/);
    client.close();
});

test("CDP rejects oversized requests without transmitting them", async (context) =>
{
    mockSocket(context);
    const client = await CdpClient.connect(SOCKET, PORT);
    await assert.rejects(client.request("Huge", { value: "x".repeat(2 * 1024 * 1024) }), /Unable to send/);
    assert.equal(MockSocket.instances[0]!.requests.length, 0);
    client.close();
});

test("pristine build gating is read-only and rejects the wrong version, commit and native hash", async (context) =>
{
    mockSocket(context);
    const appRoot = await buildFixture(context, false);
    const center = new RuntimeCenter("runtime", OWNER, appRoot, PORT);
    const original = await readFile(join(appRoot, "out/vs/workbench/workbench.desktop.main.js"));
    await writeFile(join(appRoot, "package.json"), JSON.stringify({ version: "1.125.0" }));
    await assert.rejects(center.attach(CONTENT), /Unsupported Desktop build/);
    await writeFile(join(appRoot, "package.json"), JSON.stringify({ version: "1.126.0" }));
    await writeFile(join(appRoot, "product.json"), JSON.stringify({ commit: "other" }));
    await assert.rejects(center.attach(CONTENT), /Unsupported Desktop build/);
    await writeFile(join(appRoot, "product.json"), JSON.stringify({ commit: COMMIT }));
    await assert.rejects(center.attach(CONTENT), /verified pristine/);
    assert.deepEqual(await readFile(join(appRoot, "out/vs/workbench/workbench.desktop.main.js")), original);
    assert.equal(MockSocket.instances.length, 0);
});

test("identity discovery ignores iframes and other URLs and only captures the matching window", async (context) =>
{
    mockSocket(context);
    const appRoot = await buildFixture(context);
    const other = `ws://127.0.0.1:${PORT}/devtools/page/other`;
    mockTargets(context, [
        { type: "iframe", url: workbenchUrl(appRoot), webSocketDebuggerUrl: SOCKET + "-iframe" },
        { type: "page", url: "https://example.com/workbench.html", webSocketDebuggerUrl: SOCKET + "-remote" },
        { type: "page", url: workbenchUrl(appRoot) + "?unexpected", webSocketDebuggerUrl: SOCKET + "-query" },
        { type: "page", url: workbenchUrl(appRoot), webSocketDebuggerUrl: other },
        { type: "page", url: workbenchUrl(appRoot), webSocketDebuggerUrl: SOCKET },
    ]);
    rendererHandler({ [other]: "other-activation", [SOCKET]: OWNER });
    const center = new RuntimeCenter("var AutonomNative={};", OWNER, appRoot, PORT);
    context.after(() => center.detach());
    assert.deepEqual(await center.attach(CONTENT), STATUS);
    assert.equal(MockSocket.instances.length, 2);
    const unmatched = MockSocket.instances[0]!;
    const matched = MockSocket.instances[1]!;
    assert.equal(unmatched.readyState, 3);
    assert.equal(methods(unmatched).includes("Debugger.enable"), false);
    const unmatchedExpressions = unmatched.requests.filter((request) => request.method === "Runtime.evaluate")
        .map((request) => request.params.expression);
    assert.equal(unmatchedExpressions.length, 2);
    assert.ok(unmatchedExpressions[0].includes("autonomCenter.bridgeIdentity"));
    assert.equal(unmatchedExpressions[1], "delete globalThis.__autonomAttachProbe;");
    assert.equal(methods(matched).filter((method) => method === "Debugger.setBreakpointOnFunctionCall").length, 2);
    assert.equal(methods(matched).filter((method) => method === "Debugger.resume").length, 2);
    assert.equal(methods(matched).includes("Runtime.getProperties"), false);
    const frames = matched.requests.filter((request) => request.method === "Debugger.evaluateOnCallFrame");
    assert.ok(frames[0]!.params.expression.includes("controller:yAe.prototype"));
    assert.ok(frames[1]!.params.expression.includes("windowId=e.vscodeWindowId"));
    for (let i = 0; i < matched.requests.length; i++)
    {
        if (matched.requests[i]!.method === "Debugger.evaluateOnCallFrame")
        {
            assert.equal(matched.requests[i + 1]!.method, "Debugger.removeBreakpoint");
            assert.equal(matched.requests[i + 2]!.method, "Debugger.resume");
        }
    }
    assert.ok(methods(matched).indexOf("Debugger.disable") > methods(matched).lastIndexOf("Debugger.resume"));
    assertReleasedGroups(unmatched);
    assertReleasedGroups(matched);
    assert.deepEqual(await center.update({ ...CONTENT, revision: "second" }), STATUS);
    assert.deepEqual(await center.status(), STATUS);
    assert.deepEqual(await center.open("hello"), STATUS);
    assert.equal(methods(matched).filter((method) => method === "Debugger.enable").length, 1);
    assert.equal(Object.hasOwn(await center.status(), "unexpectedSecret"), false);
    await center.detach();
    assert.equal(matched.readyState, 3);
    assert.equal((await center.status()).connected, false);
    assertReleasedGroups(matched);
});

test("duplicate matching identities fail closed without installing or capturing services", async (context) =>
{
    mockSocket(context);
    const appRoot = await buildFixture(context);
    const other = SOCKET + "-duplicate";
    mockTargets(context, [
        { type: "page", url: workbenchUrl(appRoot), webSocketDebuggerUrl: SOCKET },
        { type: "page", url: workbenchUrl(appRoot), webSocketDebuggerUrl: other },
    ]);
    rendererHandler({ [SOCKET]: OWNER, [other]: OWNER });
    const center = new RuntimeCenter("runtime", OWNER, appRoot, PORT);
    await assert.rejects(center.attach(CONTENT), /Multiple Desktop windows/);
    for (const socket of MockSocket.instances)
    {
        assert.equal(socket.readyState, 3);
        assert.equal(methods(socket).includes("Debugger.enable"), false);
        assert.ok(socket.requests.some((request) =>
        {
            return request.params.expression === "delete globalThis.__autonomAttachProbe;";
        }));
        assertReleasedGroups(socket);
    }
});

test("no matching sidebar identity reports native preparation and performs no installation", async (context) =>
{
    mockSocket(context);
    const appRoot = await buildFixture(context);
    mockTargets(context, [{ type: "page", url: workbenchUrl(appRoot), webSocketDebuggerUrl: SOCKET }]);
    rendererHandler({ [SOCKET]: null });
    const center = new RuntimeCenter("runtime", OWNER, appRoot, PORT);
    await assert.rejects(center.attach(CONTENT), /Prepare the native Command Center first/);
    const socket = MockSocket.instances[0]!;
    assert.equal(socket.readyState, 3);
    assert.equal(methods(socket).includes("Debugger.enable"), false);
});

test("capture errors remove the owned breakpoint, resume, disable and clear temporary references", async (context) =>
{
    mockSocket(context);
    const appRoot = await buildFixture(context);
    mockTargets(context, [{ type: "page", url: workbenchUrl(appRoot), webSocketDebuggerUrl: SOCKET }]);
    rendererHandler({ [SOCKET]: OWNER });
    const normal = MockSocket.handler;
    MockSocket.handler = (socket, request) =>
    {
        if (request.method === "Debugger.evaluateOnCallFrame")
        {
            socket.reply(request.id, { exceptionDetails: { text: "never expose exception details" } });
        }
        else
        {
            normal(socket, request);
        }
    };
    const center = new RuntimeCenter("runtime", OWNER, appRoot, PORT);
    await assert.rejects(center.attach(CONTENT), /service capture failed/);
    const socket = MockSocket.instances[0]!;
    const sequence = methods(socket);
    assert.equal(sequence.filter((method) => method === "Debugger.removeBreakpoint").length, 1);
    assert.equal(sequence.filter((method) => method === "Debugger.resume").length, 1);
    assert.equal(sequence.filter((method) => method === "Debugger.disable").length, 1);
    assert.ok(sequence.indexOf("Debugger.removeBreakpoint") < sequence.indexOf("Debugger.resume"));
    assert.ok(sequence.indexOf("Debugger.resume") < sequence.indexOf("Debugger.disable"));
    assert.ok(socket.requests.some((request) => request.params.expression
        === "delete globalThis.__autonomAttachProbe;delete globalThis.__autonomServices;"));
    assert.equal(socket.readyState, 3);
    assertReleasedGroups(socket);
});

test("target discovery is bounded and refuses redirects and unsafe matching socket URLs", async (context) =>
{
    mockSocket(context);
    const appRoot = await buildFixture(context);
    const center = new RuntimeCenter("runtime", OWNER, appRoot, PORT);
    for (const body of [
        " ".repeat(1024 * 1024 + 1),
        JSON.stringify(Array.from({ length: 129 }, () => ({}))),
        JSON.stringify([{ type: "page", url: workbenchUrl(appRoot), webSocketDebuggerUrl: "ws://evil.test/test" }]),
        "{}",
    ])
    {
        context.mock.method(globalThis, "fetch", async (_address: unknown, options?: RequestInit) =>
        {
            assert.equal(options?.redirect, "error");
            return new Response(body);
        });
        await assert.rejects(center.attach(CONTENT), /Cannot discover Desktop renderers/);
    }
    context.mock.method(globalThis, "fetch", async () =>
    {
        throw new Error("redirect refused");
    });
    await assert.rejects(center.attach(CONTENT), /Cannot discover Desktop renderers/);
    assert.equal(MockSocket.instances.length, 0);
});

test("patch-only warning suppression fails closed without verified recovery evidence", async (context) =>
{
    const appRoot = await buildFixture(context);
    assert.equal(await verifyPatchOnlyWarningCase(appRoot), false);
});

test("attach, update, open and detach are serialized without recapturing an owned runtime", async (context) =>
{
    mockSocket(context);
    const appRoot = await buildFixture(context);
    mockTargets(context, [{ type: "page", url: workbenchUrl(appRoot), webSocketDebuggerUrl: SOCKET }]);
    rendererHandler({ [SOCKET]: OWNER });
    const center = new RuntimeCenter("runtime", OWNER, appRoot, PORT);
    const attached = center.attach(CONTENT);
    const updated = center.update(CONTENT);
    const opened = center.open("hello");
    const detached = center.detach();
    await Promise.all([attached, updated, opened, detached]);
    const socket = MockSocket.instances[0]!;
    assert.equal(MockSocket.instances.length, 1);
    assert.equal(methods(socket).filter((method) => method === "Debugger.enable").length, 1);
    const expressions = socket.requests.filter((request) => request.method === "Runtime.evaluate")
        .map((request) => request.params.expression as string);
    const install = expressions.findIndex((expression) => expression.includes("AutonomNative.install"));
    const update = expressions.findIndex((expression) => expression.includes("__autonomCenter.update"));
    const open = expressions.findIndex((expression) => expression.includes("__autonomCenter.open"));
    const dispose = expressions.findIndex((expression) => expression.includes("runtime.dispose()"));
    assert.ok(install < update && update < open && open < dispose);
    assert.equal(socket.readyState, 3);
});
