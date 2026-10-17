import { object, text } from "../parse";
import type { CdpSession } from "./client";
import { exceptionText, requestTimeout } from "./client";

import { randomUUID } from "node:crypto";

function probe(): any
{
    for (const element of document.querySelectorAll("[data-slot=sidebar-menu], [data-slot=sidebar]"))
    {
        const key = Object.keys(element).find((name) => name.startsWith("__reactFiber$"));
        let fiber = key ? (element as any)[key] : null;
        for (let index = 0; fiber && index < 128; index++, fiber = fiber.return)
        {
            const props = fiber.memoizedProps;
            if (typeof props?.getDesktopNavSurfacesSnapshot === "function"
                && typeof props?.getActiveDesktopNavSurfaceSnapshot === "function" && props.vscodeAPI?.executeCommand)
                return { props, api: props.vscodeAPI };
        }
    }

    return null;
}

export async function captureServices(session: CdpSession): Promise<boolean>
{
    const found = await session.evaluate(`globalThis.__autonomAttachProbe=(${probe.toString()})();`
        + "Boolean(globalThis.__autonomAttachProbe)");
    if (found !== true)
        return false;

    await session.request("Debugger.enable", { maxScriptsCacheSize: 0 });
    try
    {
        await captureInvocation(
            session,
            "globalThis.__autonomAttachProbe.props.getDesktopNavSurfacesSnapshot",
            "globalThis.__autonomServices={manifest:this._manifestService,controller:yAe.prototype};true",
        );
        await captureInvocation(
            session,
            "globalThis.__autonomAttachProbe.props.getActiveDesktopNavSurfaceSnapshot",
            "globalThis.__autonomServices.groups=o;globalThis.__autonomServices.windowId=e.vscodeWindowId;"
                + "globalThis.__autonomServices.api=globalThis.__autonomAttachProbe.api;true",
        );
        return true;
    }
    finally
    {
        await session.request("Debugger.disable").catch(() => undefined);
        await session.evaluate("delete globalThis.__autonomAttachProbe").catch(() => undefined);
    }
}

export async function captureInvocation(session: CdpSession, expression: string, assignments: string): Promise<void>
{
    const group = `autonom-capture-${randomUUID()}`;
    const reference = await session.request("Runtime.evaluate", { expression, objectGroup: group });
    const target = object(reference.result);
    if (reference.exceptionDetails || typeof target?.objectId !== "string" || target.type !== "function")
        throw new Error("The Devin agent sidebar is not mounted. Open the agent window and retry.");
    const breakpoint = await session.request("Debugger.setBreakpointOnFunctionCall", { objectId: target.objectId });
    const breakpointId = text(breakpoint.breakpointId);
    if (!breakpointId)
        throw new Error("The native service capture breakpoint was not installed.");
    let paused = false;
    let cleanup: Promise<void> | undefined;
    const finish = (): Promise<void> => cleanup ??= (async () =>
    {
        try
        {
            await session.request("Debugger.removeBreakpoint", { breakpointId });
        }
        finally
        {
            if (paused)
                await session.request("Debugger.resume");
        }
    })();
    let timer: ReturnType<typeof setTimeout> | undefined;
    let removeListener: (() => void) | undefined;
    const captured = new Promise<void>((resolve_, reject) =>
    {
        timer = setTimeout(() =>
        {
            reject(new Error("Timed out capturing the native Command Center services."));
        }, requestTimeout);
        removeListener = session.on("Debugger.paused", (parameters) =>
        {
            const hit = Array.isArray(parameters.hitBreakpoints) && parameters.hitBreakpoints.includes(breakpointId);
            if (paused || !hit)
                return;
            paused = true;
            removeListener?.();
            void (async () =>
            {
                try
                {
                    const frames = Array.isArray(parameters.callFrames) ? parameters.callFrames : [];
                    const callFrameId = text(object(frames[0])?.callFrameId);
                    if (!callFrameId)
                        throw new Error("The native service capture has no call frame.");
                    const ret = await session.request("Debugger.evaluateOnCallFrame", {
                        callFrameId,
                        expression: assignments,
                        objectGroup: group,
                        returnByValue: true,
                    });
                    if (ret.exceptionDetails)
                        throw new Error(exceptionText(ret) ?? "The native Command Center service capture failed.");
                    await finish();
                    resolve_();
                }
                catch (error)
                {
                    await finish().catch(() => undefined);
                    reject(error instanceof Error ? error : new Error("The native service capture failed."));
                }
            })();
        });
    });
    try
    {
        await Promise.all([captured, session.evaluate(`${expression}()`)]);
    }
    finally
    {
        clearTimeout(timer);
        removeListener?.();
        await finish();
        await session.request("Runtime.releaseObjectGroup", { objectGroup: group }).catch(() => undefined);
    }
}
