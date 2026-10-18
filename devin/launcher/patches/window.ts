import { captureServices } from "./capture";
import type { CdpSession } from "../cdp/client";
import type { RuntimeConfig, RuntimeStatus } from "../center/types";
import type { PatchStatus } from "./lifecycle";

import { createHash } from "node:crypto";

const captures = new WeakMap<CdpSession, PatchStatus>();

export async function windowPatches(session: CdpSession): Promise<unknown[]>
{
    const renderer = await session.evaluate("globalThis.__autonomBundle?.runtime.patchStatus() ?? []") as unknown[];
    return [...(captures.has(session) ? [captures.get(session)] : []), ...renderer];
}

export async function runtimeStatus(session: CdpSession): Promise<RuntimeStatus | null>
{
    return await session.evaluate(`(() => {
        const runtime = globalThis.__autonomCenter;
        if (!runtime) return null;
        runtime.heartbeat();
        const status = runtime.status();
        return {
            connected: status.connected, mode: status.mode, enabled: status.enabled,
            revision: status.revision, activeItem: status.activeItem, windowId: status.windowId,
            editorActive: status.editorActive,
            items: status.items.slice(0, 100).map(({id, label, path}) => ({id, label, path})),
            sections: status.sections, spaces: status.spaces,
            loadedActions: status.loadedActions, compiledScripts: status.compiledScripts
        };
    })()`) as RuntimeStatus | null;
}

export async function installRuntime(
    session: CdpSession, source: string, config: RuntimeConfig,
    timing?: (phase: string, duration: number) => void,
): Promise<RuntimeStatus | null>
{
    await ensureBundle(session, source);
    captures.set(session, { name: "native-services", state: "installed" });
    try
    {
        if (!await captureServices(session, timing))
            throw new Error("The agent sidebar is not mounted. Open the agent window (Ctrl+').");

        await session.evaluate(`(async () => {
            const config = ${JSON.stringify(config)};
            const runtime = globalThis.__autonomBundle.runtime.install(globalThis.__autonomServices, config);
            try {
                globalThis.__autonomBundle.runtime.prepareShell(config.content.css, globalThis.__autonomBundle.icons);
                await runtime.update(config);
            }
            catch (error) { runtime.dispose(); throw error; }
        })()`, 45000);
        return await runtimeStatus(session);
    }
    catch (error)
    {
        captures.set(session, { name: "native-services", state: "failed",
            errors: [error instanceof Error ? error.message : String(error)] });
        throw error;
    }
    finally
    {
        await session.evaluate("delete globalThis.__autonomServices").catch(() => undefined);
        if (captures.get(session)?.state !== "failed")
            captures.set(session, { name: "native-services", state: "restored" });
    }
}

export async function executeScript(
    session: CdpSession, id: string, actionVersion: string, source: string,
): Promise<void>
{
    const key = JSON.stringify(id);
    const version = JSON.stringify(actionVersion);
    if (!await session.evaluate(`globalThis.__autonomCenter?.hasScript(${key},${version})`))
        await session.evaluate(`globalThis.__autonomCenter.setScript(${key},${version},async (context) => {\n`
            + `${source}\n});`);

    await session.evaluate(`globalThis.__autonomCenter.runScript(${key},${version})`, 45000);
}

async function ensureBundle(session: CdpSession, source: string): Promise<void>
{
    const version = createHash("sha256").update(source).digest("hex");
    if (await session.evaluate(`globalThis.__autonomBundle?.version === ${JSON.stringify(version)}`))
        return;

    await session.evaluate(`(() => {
        ${source}
        globalThis.__autonomBundle = {version:${JSON.stringify(version)}, runtime:AutonomRuntime,
            icons:globalThis.__autonomBundle?.icons};
    })()`);
}

export async function prepareWindow(
    session: CdpSession, source: string, css: string, icons: Record<string, string>,
): Promise<void>
{
    await ensureBundle(session, source);
    await session.evaluate(`(() => {
        if (!document.head || !document.body) return;
        globalThis.__autonomBundle.icons = ${JSON.stringify(icons)};
        globalThis.__autonomBundle.runtime.prepareShell(${JSON.stringify(css)}, globalThis.__autonomBundle.icons);
    })()`);
}
