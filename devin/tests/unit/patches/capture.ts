import { captureInvocation, captureServices } from "../../../launcher/patches/capture";
import { requestTimeout } from "../../../launcher/cdp/client";
import { attach, fakeBrowser, reply } from "../../cdp-browser";

import assert from "node:assert/strict";
import { test } from "node:test";

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
    assert.ok(browser.requests.some((request) => request.method === "Runtime.releaseObjectGroup"
        && String(request.params.objectGroup).startsWith("autonom-capture-")));
});

function captureBrowser(options: {
    fail?: string;
    found?: boolean;
    probeFailure?: boolean;
    invokeFailure?: boolean;
    noPause?: boolean;
    missingBreakpoint?: boolean;
    missingFrame?: boolean;
    frameFailureAt?: number;
} = {})
{
    let frames = 0;
    const browser = fakeBrowser((request) =>
    {
        const failure = () => ({ id: request.id, error: { message: `Rejected ${request.method}` } });
        if (request.method === options.fail && (request.method !== "Runtime.evaluate" || !request.params.returnByValue))
            return failure();

        if (request.method === "Debugger.setBreakpointOnFunctionCall")
            return reply(request, options.missingBreakpoint ? {} : { breakpointId: "bp-1" });

        if (request.method === "Debugger.evaluateOnCallFrame")
        {
            frames++;
            return reply(request, frames === options.frameFailureAt
                ? { exceptionDetails: { text: "capture assignment failed" } } : {});
        }

        if (request.method === "Runtime.evaluate")
        {
            const expression = String(request.params.expression);
            if (expression.startsWith("globalThis.__autonomAttachProbe=("))
                return options.probeFailure ? failure() : reply(request, { result: { value: options.found ?? true } });

            if (!request.params.returnByValue)
                return reply(request, { result: { type: "function", objectId: "native-function" } });

            if (expression.endsWith("()"))
            {
                if (options.invokeFailure)
                    return failure();

                if (!options.noPause)
                    setImmediate(() => browser.emit({
                        method: "Debugger.paused", sessionId: "session-1",
                        params: { hitBreakpoints: ["bp-1"], callFrames: options.missingFrame ? [] : [{ callFrameId: "frame-1" }] },
                    }));
            }

            return reply(request, { result: {} });
        }

        return attach(request) ?? reply(request, {});
    });
    return browser;
}

for (const failure of ["Runtime.evaluate", "Debugger.setBreakpointOnFunctionCall", "Debugger.removeBreakpoint", "Debugger.resume"])
{
    test(`captureInvocation releases its object group when ${failure} fails`, async () =>
    {
        const browser = captureBrowser({ fail: failure });
        const session = await browser.client.attach("page-1");
        await assert.rejects(captureInvocation(session, "native.snapshot", "assign();"), /Rejected/);
        const releases = browser.requests.filter((request) => request.method === "Runtime.releaseObjectGroup"
            && String(request.params.objectGroup).startsWith("autonom-capture-"));
        assert.equal(releases.length, 1);
        if (failure === "Debugger.removeBreakpoint" || failure === "Debugger.resume")
        {
            assert.equal(browser.requests.filter((request) => request.method === "Debugger.removeBreakpoint").length, 1);
            assert.equal(browser.requests.filter((request) => request.method === "Debugger.resume").length, 1);
        }

        const count = browser.requests.length;
        browser.emit({ method: "Debugger.paused", sessionId: "session-1", params: { hitBreakpoints: ["bp-1"] } });
        assert.equal(browser.requests.length, count, "The capture listener must be removed after failure.");
    });
}

for (const scenario of [
    { name: "missing breakpoint id", options: { missingBreakpoint: true }, pattern: /breakpoint was not installed/ },
    { name: "missing call frame", options: { missingFrame: true }, pattern: /no call frame/ },
    { name: "assignment failure", options: { frameFailureAt: 1 }, pattern: /capture assignment failed/ },
    { name: "invocation failure", options: { invokeFailure: true }, pattern: /Rejected Runtime.evaluate/ },
])
{
    test(`captureInvocation cleans up after ${scenario.name}`, async () =>
    {
        const browser = captureBrowser(scenario.options);
        const session = await browser.client.attach("page-1");
        await assert.rejects(captureInvocation(session, "native.snapshot", "assign();"), scenario.pattern);
        assert.ok(browser.requests.some((request) => request.method === "Runtime.releaseObjectGroup"
            && String(request.params.objectGroup).startsWith("autonom-capture-")));
        if (!scenario.options.missingBreakpoint)
            assert.ok(browser.requests.some((request) => request.method === "Debugger.removeBreakpoint"));

        if (scenario.options.missingFrame || scenario.options.frameFailureAt)
            assert.ok(browser.requests.some((request) => request.method === "Debugger.resume"));
    });
}

test("captureInvocation times out without resuming an unrelated debugger pause", async (context) =>
{
    const browser = captureBrowser({ noPause: true });
    const session = await browser.client.attach("page-1");
    context.mock.timers.enable({ apis: ["setTimeout"] });
    const rejected = assert.rejects(captureInvocation(session, "native.snapshot", "assign();"), /Timed out capturing/);
    await new Promise((resolve) => setImmediate(resolve));
    browser.emit({ method: "Debugger.paused", sessionId: "session-1", params: { hitBreakpoints: ["other-breakpoint"] } });
    context.mock.timers.tick(requestTimeout);
    await rejected;
    assert.ok(browser.requests.some((request) => request.method === "Debugger.removeBreakpoint"));
    assert.ok(!browser.requests.some((request) => request.method === "Debugger.resume"));
    assert.ok(browser.requests.some((request) => request.method === "Runtime.releaseObjectGroup"
        && String(request.params.objectGroup).startsWith("autonom-capture-")));
});

test("captureServices removes scratch globals when the native sidebar is absent", async () =>
{
    const browser = captureBrowser({ found: false });
    const session = await browser.client.attach("page-1");
    assert.equal(await captureServices(session), false);
    const expressions = browser.requests.filter((request) => request.method === "Runtime.evaluate")
        .map((request) => String(request.params.expression));
    assert.ok(expressions.some((expression) => expression.includes("delete globalThis.__autonomAttachProbe")
        && expression.includes("delete globalThis.__autonomServices")));
    assert.ok(!browser.requests.some((request) => request.method === "Debugger.enable"));
});

for (const scenario of [
    { name: "probe failure", options: { probeFailure: true }, debuggerAttempted: false },
    { name: "debugger enable failure", options: { fail: "Debugger.enable" }, debuggerAttempted: true },
    { name: "partial service capture", options: { frameFailureAt: 2 }, debuggerAttempted: true },
])
{
    test(`captureServices removes partial state after ${scenario.name}`, async () =>
    {
        const browser = captureBrowser(scenario.options);
        const session = await browser.client.attach("page-1");
        await assert.rejects(captureServices(session), /Rejected|capture assignment failed/);
        const expressions = browser.requests.filter((request) => request.method === "Runtime.evaluate")
            .map((request) => String(request.params.expression));
        assert.ok(expressions.some((expression) => expression.includes("delete globalThis.__autonomAttachProbe")
            && expression.includes("delete globalThis.__autonomServices")));
        assert.equal(browser.requests.some((request) => request.method === "Debugger.disable"), scenario.debuggerAttempted);
    });
}

test("captureServices keeps completed services and treats debugger disable as best effort", async () =>
{
    const browser = captureBrowser({ fail: "Debugger.disable" });
    const session = await browser.client.attach("page-1");
    const phases: string[] = [];
    assert.equal(await captureServices(session, (phase) => phases.push(phase)), true);
    assert.deepEqual(phases, ["debugger-ready", "manifest-captured", "services-captured"]);
    const expressions = browser.requests.filter((request) => request.method === "Runtime.evaluate")
        .map((request) => String(request.params.expression));
    assert.ok(expressions.some((expression) => expression.includes("delete globalThis.__autonomAttachProbe")));
    assert.ok(!expressions.some((expression) => expression.includes("delete globalThis.__autonomServices")));
});
