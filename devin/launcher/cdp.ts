import type { CdpTransport } from "./desktop";
import { object, text } from "./config";

import { randomUUID } from "node:crypto";

const REQUEST_TIMEOUT = 8000;

export type TargetInfo = {
    id: string;
    type: string;
    url: string;
};

type PendingRequest = {
    resolve: (value: Record<string, unknown>) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
};

type EventListener = (parameters: Record<string, unknown>, sessionId: string | undefined) => void;

export class CdpClient
{
    private readonly requests = new Map<number, PendingRequest>();
    private readonly listeners = new Map<string, Set<EventListener>>();
    private sequence = 0;
    private closed = false;

    constructor(private readonly transport: CdpTransport)
    {
        transport.onMessage((message) =>
        {
            this.receive(message);
        });
        transport.onClose(() =>
        {
            this.fail(new Error("The Desktop debugging pipe closed."));
        });
    }

    request(method: string, parameters: Record<string, unknown> = {},
        sessionId?: string, timeout = REQUEST_TIMEOUT): Promise<Record<string, unknown>>
    {
        if (this.closed)
            return Promise.reject(new Error("The Desktop debugging pipe is closed."));
        const id = ++this.sequence;
        return new Promise((resolve_, reject) =>
        {
            const timer = setTimeout(() =>
            {
                this.requests.delete(id);
                reject(new Error(`Timed out waiting for ${method}.`));
            }, timeout);
            this.requests.set(id, { resolve: resolve_, reject, timer });
            try
            {
                this.transport.send({ id, method, params: parameters, ...(sessionId ? { sessionId } : {}) });
            }
            catch
            {
                this.requests.delete(id);
                clearTimeout(timer);
                reject(new Error("Unable to send the renderer debugging request."));
            }
        });
    }

    on(method: string, listener: EventListener): () => void
    {
        let listeners = this.listeners.get(method);
        if (!listeners)
        {
            listeners = new Set();
            this.listeners.set(method, listeners);
        }
        listeners.add(listener);
        return () =>
        {
            listeners.delete(listener);
            if (!listeners.size)
                this.listeners.delete(method);
        };
    }

    async targets(): Promise<TargetInfo[]>
    {
        const ret = await this.request("Target.getTargets");
        const infos = Array.isArray(ret.targetInfos) ? ret.targetInfos : [];
        const ret2: TargetInfo[] = [];
        for (const info of infos)
        {
            const target = object(info);
            if (target === undefined || typeof target.type !== "string" || typeof target.url !== "string")
                continue;
            ret2.push({ id: text(target.targetId), type: target.type, url: target.url });
        }
        return ret2;
    }

    async attach(targetId: string): Promise<CdpSession>
    {
        const ret = await this.request("Target.attachToTarget", { targetId, flatten: true });
        const sessionId = text(ret.sessionId);
        if (!sessionId)
            throw new Error("Desktop refused the renderer attachment.");
        return new CdpSession(this, sessionId, targetId);
    }

    close(): void
    {
        this.fail(new Error("The renderer debugging connection was closed."));
    }

    private fail(error: Error): void
    {
        if (this.closed)
            return;
        this.closed = true;
        for (const request of this.requests.values())
        {
            clearTimeout(request.timer);
            request.reject(error);
        }
        this.requests.clear();
        this.listeners.clear();
    }

    private receive(message: unknown): void
    {
        if (this.closed)
            return;
        const record = object(message);
        if (record === undefined)
            return;
        const sessionId = typeof record.sessionId === "string" ? record.sessionId : undefined;
        if (typeof record.id === "number")
        {
            const request = this.requests.get(record.id);
            if (!request)
                return;
            this.requests.delete(record.id);
            clearTimeout(request.timer);
            const failure = object(record.error);
            if (failure)
                request.reject(new Error(text(failure.message, "The renderer rejected a debugging request.")));
            else
                request.resolve(object(record.result) ?? {});
            return;
        }
        if (typeof record.method !== "string")
            return;
        const parameters = object(record.params) ?? {};
        for (const listener of this.listeners.get(record.method) ?? [])
            listener(parameters, sessionId);
    }
}

export class CdpSession
{
    constructor(private readonly client: CdpClient, readonly id: string, readonly targetId: string)
    {
    }

    request(method: string, parameters: Record<string, unknown> = {},
        timeout = REQUEST_TIMEOUT): Promise<Record<string, unknown>>
    {
        return this.client.request(method, parameters, this.id, timeout);
    }

    on(method: string, listener: (parameters: Record<string, unknown>) => void): () => void
    {
        return this.client.on(method, (parameters, sessionId) =>
        {
            if (sessionId === this.id)
                listener(parameters);
        });
    }

    async evaluate(expression: string, timeout = REQUEST_TIMEOUT): Promise<unknown>
    {
        const group = `autonom-evaluate-${randomUUID()}`;
        try
        {
            const ret = await this.request("Runtime.evaluate", {
                expression,
                objectGroup: group,
                returnByValue: true,
                awaitPromise: true,
            }, timeout);
            if (ret.exceptionDetails || !ret.result)
                throw new Error(exceptionText(ret) ?? "The renderer evaluation failed.");
            return object(ret.result)?.value;
        }
        finally
        {
            await this.request("Runtime.releaseObjectGroup", { objectGroup: group }).catch(() => undefined);
        }
    }

    async detach(): Promise<void>
    {
        await this.client.request("Target.detachFromTarget", { sessionId: this.id }).catch(() => undefined);
    }
}

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
        }, REQUEST_TIMEOUT);
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

function exceptionText(ret: Record<string, unknown>): string | undefined
{
    const details = object(ret.exceptionDetails);
    const description = text(object(details?.exception)?.description, text(details?.text));
    return description ? `Renderer evaluation failed: ${description.split("\n")[0]}` : undefined;
}
