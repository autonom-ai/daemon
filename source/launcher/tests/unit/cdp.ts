import { captureInvocation, CdpClient } from "../../cdp";
import { PipeTransport } from "../../desktop";

import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { test } from "node:test";

type Request = { id: number; method: string; params: Record<string, any>; sessionId?: string };
type Handler = (request: Request) => unknown;

function fakeBrowser(handler: Handler): { client: CdpClient; requests: Request[]; emit: (message: unknown) => void }
{
    const readable = new PassThrough();
    const writable = new PassThrough();
    const client = new CdpClient(new PipeTransport(readable, writable));
    const requests: Request[] = [];
    let buffer = "";
    writable.on("data", (chunk: Buffer) =>
    {
        buffer += chunk.toString("utf8");
        let end = buffer.indexOf("\0");
        while (end >= 0)
        {
            const line = buffer.slice(0, end);
            buffer = buffer.slice(end + 1);
            end = buffer.indexOf("\0");
            if (!line)
                continue;
            const request = JSON.parse(line) as Request;
            requests.push(request);
            const reply = handler(request);
            if (reply !== undefined)
                readable.write(`${JSON.stringify(reply)}\0`);
        }
    });
    return {
        client,
        requests,
        emit: (message: unknown) =>
        {
            readable.write(`${JSON.stringify(message)}\0`);
        },
    };
}

function reply(request: Request, result: Record<string, unknown>): unknown
{
    return { id: request.id, result };
}

function attach(request: Request): unknown
{
    return request.method === "Target.attachToTarget" ? reply(request, { sessionId: "session-1" }) : undefined;
}

test("requests correlate by id and renderer errors propagate", async () =>
{
    const browser = fakeBrowser((request) =>
    {
        if (request.method === "Target.getTargets")
            return reply(request, { targetInfos: [] });
        return { id: request.id, error: { message: "No such target" } };
    });
    assert.deepEqual(await browser.client.request("Target.getTargets"), { targetInfos: [] });
    await assert.rejects(browser.client.request("Target.attachToTarget", { targetId: "x" }), /No such target/);
});

test("targets and sessions are scoped to the flattened session id", async () =>
{
    const browser = fakeBrowser((request) =>
    {
        if (request.method === "Target.getTargets")
        {
            return reply(request, {
                targetInfos: [
                    { targetId: "page-1", type: "page", url: "vscode-file://vscode-app/workbench/workbench.html" },
                    { targetId: "worker-1", type: "worker" },
                ],
            });
        }
        if (request.method === "Target.attachToTarget")
            return reply(request, { sessionId: "session-1" });
        return reply(request, { ok: true });
    });
    assert.deepEqual(await browser.client.targets(), [
        { id: "page-1", type: "page", url: "vscode-file://vscode-app/workbench/workbench.html" },
    ]);
    const session = await browser.client.attach("page-1");
    assert.equal(session.id, "session-1");
    await session.request("Runtime.evaluate", { expression: "1" });
    const last = browser.requests.at(-1)!;
    assert.equal(last.sessionId, "session-1");
    await session.detach();
    assert.equal(browser.requests.at(-1)!.method, "Target.detachFromTarget");
});

test("session events are filtered by session id", async () =>
{
    const browser = fakeBrowser((request) => reply(request, { sessionId: "session-1" }));
    const session = await browser.client.attach("page-1");
    const seen: string[] = [];
    session.on("Debugger.paused", (parameters) =>
    {
        seen.push(String(parameters.reason));
    });
    browser.emit({ method: "Debugger.paused", params: { reason: "other" }, sessionId: "session-2" });
    browser.emit({ method: "Debugger.paused", params: { reason: "breakpoint" }, sessionId: "session-1" });
    assert.deepEqual(seen, ["breakpoint"]);
});

test("evaluate returns by value, reports exceptions, and releases its group", async () =>
{
    const browser = fakeBrowser((request) =>
    {
        if (request.method === "Runtime.evaluate" && request.params.expression === "1+1")
            return reply(request, { result: { type: "number", value: 2 } });
        if (request.method === "Runtime.evaluate")
            return reply(request, { exceptionDetails: { exception: { description: "TypeError: boom" } } });
        return attach(request) ?? reply(request, {});
    });
    assert.equal(await browser.client.attach("page-1").then((session) => session.evaluate("1+1")), 2);
    const session = await browser.client.attach("page-1");
    await assert.rejects(session.evaluate("throw new Error()"), /TypeError: boom/);
    assert.ok(browser.requests.some((request) => request.method === "Runtime.releaseObjectGroup"));
});

test("captureInvocation pauses at the function, evaluates in the frame, and resumes", async () =>
{
    const browser = fakeBrowser((request) =>
    {
        switch (request.method)
        {
            case "Debugger.setBreakpointOnFunctionCall":
                return reply(request, { breakpointId: "bp-1" });
            case "Debugger.evaluateOnCallFrame":
                assert.equal(request.params.callFrameId, "frame-1");
                assert.equal(request.params.expression, "assign();");
                return reply(request, {});
            case "Runtime.evaluate":
                if (String(request.params.expression).endsWith("()"))
                {
                    setImmediate(() =>
                    {
                        browser.emit({
                            method: "Debugger.paused",
                            params: { hitBreakpoints: ["bp-1"], callFrames: [{ callFrameId: "frame-1" }] },
                            sessionId: "session-1",
                        });
                    });
                    return reply(request, { result: {} });
                }
                return reply(request, { result: { type: "function", objectId: "obj-1" } });
            default:
                return attach(request) ?? reply(request, {});
        }
    });
    const session = await browser.client.attach("page-1");
    await captureInvocation(session, "globalThis.__autonomAttachProbe.props.probe", "assign();");
    const methods = browser.requests.map((request) => request.method);
    assert.ok(methods.includes("Debugger.setBreakpointOnFunctionCall"));
    assert.ok(methods.includes("Debugger.evaluateOnCallFrame"));
    assert.ok(methods.includes("Debugger.removeBreakpoint"));
    assert.ok(methods.includes("Debugger.resume"));
});

test("captureInvocation fails closed when the agent sidebar is not mounted", async () =>
{
    const browser = fakeBrowser((request) => attach(request) ?? reply(request, { result: { type: "undefined" } }));
    const session = await browser.client.attach("page-1");
    await assert.rejects(captureInvocation(session, "globalThis.__autonomAttachProbe.props.probe", "assign();"),
        /sidebar is not mounted/);
    assert.ok(!browser.requests.some((request) => request.method === "Debugger.setBreakpointOnFunctionCall"));
});
