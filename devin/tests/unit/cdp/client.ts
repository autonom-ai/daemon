import { attach, fakeBrowser, reply } from "../../cdp-browser";

import assert from "node:assert/strict";
import { test } from "node:test";

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
    assert.equal(browser.requests.at(-1)!.sessionId, undefined);
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
