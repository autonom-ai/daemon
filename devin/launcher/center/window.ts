import { captureServices } from "../cdp/capture";
import type { CdpSession } from "../cdp/client";
import type { RuntimeConfig, RuntimeStatus } from "./types";

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
): Promise<RuntimeStatus | null>
{
    if (!await captureServices(session))
        throw new Error("The agent sidebar is not mounted. Open the agent window (Ctrl+').");

    try
    {
        await session.evaluate(`(async () => {
            ${source}
            const config = ${JSON.stringify(config)};
            const runtime = AutonomRuntime.install(globalThis.__autonomServices, config);
            try { await runtime.update(config); }
            catch (error) { runtime.dispose(); throw error; }
        })()`, 45000);
        return await runtimeStatus(session);
    }
    finally
    {
        await session.evaluate("delete globalThis.__autonomServices").catch(() => undefined);
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
