import { object, text } from "../parse";
import type { CdpSession } from "../cdp/client";
import { exceptionText, requestTimeout } from "../cdp/client";

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

export async function captureServices(
    session: CdpSession, timing?: (phase: string, duration: number) => void,
): Promise<boolean>
{
    const started = performance.now();
    const measure = (phase: string) => timing?.(phase, performance.now() - started);
    let debuggerAttempted = false;
    let captured = false;
    try
    {
        const found = await session.evaluate(`globalThis.__autonomAttachProbe=(${probe.toString()})();`
            + "Boolean(globalThis.__autonomAttachProbe)");
        if (found !== true)
            return false;

        debuggerAttempted = true;
        await session.request("Debugger.enable", { maxScriptsCacheSize: 0 });
        measure("debugger-ready");
        await captureInvocation(
            session,
            "globalThis.__autonomAttachProbe.props.getDesktopNavSurfacesSnapshot",
            "globalThis.__autonomServices={manifest:this._manifestService,controller:yAe.prototype};true",
        );
        measure("manifest-captured");
        await captureInvocation(
            session,
            "globalThis.__autonomAttachProbe.props.getActiveDesktopNavSurfaceSnapshot",
            "globalThis.__autonomServices.groups=o;globalThis.__autonomServices.windowId=e.vscodeWindowId;"
                + "globalThis.__autonomServices.api=globalThis.__autonomAttachProbe.api;true",
        );
        measure("services-captured");
        captured = true;
        return true;
    }
    finally
    {
        if (debuggerAttempted)
            await session.request("Debugger.disable").catch(() => undefined);

        await session.evaluate("delete globalThis.__autonomAttachProbe;"
            + (captured ? "" : "delete globalThis.__autonomServices;")).catch(() => undefined);
    }
}

export async function captureInvocation(session: CdpSession, expression: string, assignments: string): Promise<void>
{
    const group = `autonom-capture-${randomUUID()}`;
    let breakpointId: string | undefined;
    let paused = false;
    let cleanup: Promise<void> | undefined;
    const finish = (): Promise<void> => cleanup ??= (async () =>
    {
        try
        {
            if (breakpointId)
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
    try
    {
        const reference = await session.request("Runtime.evaluate", { expression, objectGroup: group });
        const target = object(reference.result);
        if (reference.exceptionDetails || typeof target?.objectId !== "string" || target.type !== "function")
            throw new Error("The Devin agent sidebar is not mounted. Open the agent window and retry.");

        const breakpoint = await session.request("Debugger.setBreakpointOnFunctionCall", { objectId: target.objectId });
        breakpointId = text(breakpoint.breakpointId);
        if (!breakpointId)
            throw new Error("The native service capture breakpoint was not installed.");

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
        await Promise.all([captured, session.evaluate(`${expression}()`)]);
    }
    finally
    {
        clearTimeout(timer);
        removeListener?.();
        try
        {
            await finish();
        }
        finally
        {
            await session.request("Runtime.releaseObjectGroup", { objectGroup: group }).catch(() => undefined);
        }
    }
}
