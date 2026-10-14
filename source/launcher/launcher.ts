import { captureServices, CdpClient } from "./cdp";
import type { CdpSession } from "./cdp";
import { startBridge } from "./bridge";
import { DaemonClient } from "./client";
import type { ActionCache, LauncherSettings } from "./config";
import { defaultDaemonConfigPath, defaultSettingsPath, expandPath, loadAction, loadCenter, readSettings } from "./config";
import { visibleItems } from "./center";
import { defaultSocketPath, isLauncherRunning, startControlSocket } from "./control";
import { appRootFor, launchDesktop, openInDesktop, resolveDesktopBinary, verifyDesktopBuild, workbenchUrl } from "./desktop";
import type { RuntimeStatus } from "./runtime";

import { watch } from "node:fs";
import type { FSWatcher } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, extname, join, resolve } from "node:path";

const HEARTBEAT_INTERVAL = 5000;
const ATTACH_TIMEOUT = 60000;

type Options = {
    arguments: string[];
    debugPort: number | undefined;
};

async function main(): Promise<void>
{
    const options = parseArguments(process.argv.slice(2));
    const binary = resolveDesktopBinary("devin-desktop");
    const socketPath = defaultSocketPath();
    if (await isLauncherRunning(socketPath))
    {
        if (options.debugPort !== undefined)
            log("A managed Desktop is already running; --debug cannot open a port on it. "
                + "Quit Desktop and the launcher, then relaunch.");

        openInDesktop(binary, options.arguments);
        return;
    }

    const repository = resolve(__dirname, "..");
    const settingsPath = defaultSettingsPath();
    const stored = await readSettings(settingsPath).catch((error) =>
    {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT")
            throw error;

        return {} as Partial<LauncherSettings>;
    });
    const settings: LauncherSettings = {
        port: environmentPort() ?? stored.port ?? 8080,
        configFile: expandPath(process.env.AUTONOM_CONFIG ?? stored.configFile ?? defaultDaemonConfigPath()),
        commandCenterConfig: expandPath(stored.commandCenterConfig ?? join(repository, "assets", "ui.yml")),
    };
    const appRoot = appRootFor(binary);
    await verifyDesktopBuild(appRoot);
    let contentPath = settings.commandCenterConfig;
    let content = await loadCenter(contentPath);
    const actionCache: ActionCache = new Map();
    const runtimePath = join(__dirname, "runtime.js");
    let runtimeSource = await readFile(runtimePath, "utf8");
    const client = new DaemonClient({ port: settings.port, configFile: settings.configFile, rootDirectory: repository });
    await client.connect();
    const bridge = await startBridge({
        workspace: process.cwd(),
        repository,
        settingsPath,
        settings,
        client,
        openPath: (path) => openInDesktop(binary, [path]),
        getAction: (id, revision) => loadAction(contentPath, content, id, revision, actionCache),
        runScript,
        reloadUi: hot,
    });
    const { child, transport } = await launchDesktop({
        binary,
        arguments: options.arguments,
        ...(options.debugPort === undefined ? {} : { debugPort: options.debugPort }),
    });
    const cdp = new CdpClient(transport);
    const sessions = new Map<string, CdpSession>();
    const installed = new Set<string>();
    const windows = new Map<number, CdpSession>();
    const warnings = new Map<string, string>();
    let control: { close(): Promise<void> } | undefined;
    let heartbeat: ReturnType<typeof setTimeout> | undefined;
    let disabled = false;
    let stopping = false;
    let refreshing: Promise<void> | undefined;
    let foundWindow = false;
    let watcher: FSWatcher | undefined;
    let reloadTimer: ReturnType<typeof setTimeout> | undefined;
    let reloading: Promise<unknown> | undefined;

    async function status(session: CdpSession): Promise<RuntimeStatus | null>
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
                sections: status.sections,
                loadedActions: status.loadedActions, compiledScripts: status.compiledScripts
            };
        })()`) as RuntimeStatus | null;
    }

    async function install(session: CdpSession): Promise<void>
    {
        if (!await captureServices(session))
            throw new Error("The agent sidebar is not mounted. Open the agent window (Ctrl+').");

        try
        {
            const config = JSON.stringify({ content, bridge: { url: bridge.url, token: bridge.token } });
            await session.evaluate(`(async () => {
                ${runtimeSource}
                const config = ${config};
                const runtime = AutonomRuntime.install(globalThis.__autonomServices, config);
                try { await runtime.update(config); }
                catch (error) { runtime.dispose(); throw error; }
            })()`, 45000);
            const current = await status(session);
            if (current)
            {
                windows.set(current.windowId, session);
                installed.add(session.targetId);
            }

            log(`Attached ${session.targetId}: ${current?.mode}, active ${current?.activeItem ?? "none"}`);
        }
        finally
        {
            await session.evaluate("delete globalThis.__autonomServices").catch(() => undefined);
        }
    }

    async function refreshWindows(): Promise<void>
    {
        if (disabled || stopping)
            return;

        const urls = [
            workbenchUrl(appRoot),
            `vscode-file://vscode-app${join(appRoot, "out/vs/sessions/electron-browser/sessions.html")}`,
        ];
        const targets = (await cdp.targets()).filter((target) => target.type === "page"
            && urls.includes(target.url.split(/[?#]/)[0]!));
        if (targets.length)
            foundWindow = true;

        for (const [id, session] of sessions)
        {
            if (targets.some((target) => target.id === id))
                continue;

            sessions.delete(id);
            warnings.delete(id);
            for (const [windowId, current] of windows)
                if (current === session)
                    windows.delete(windowId);

            await session.detach();
        }

        for (const target of targets)
        {
            try
            {
                let session = sessions.get(target.id);
                if (!session)
                {
                    session = await cdp.attach(target.id);
                    sessions.set(target.id, session);
                }

                await session.evaluate(`(() => {
                    if (!globalThis.__autonomShell) {
                        ${runtimeSource}
                        AutonomRuntime.prepareShell(${JSON.stringify(content.css)});
                    } else globalThis.__autonomShell.heartbeat();
                })()`);
                if (!await status(session))
                    await install(session);

                warnings.delete(target.id);
            }
            catch (error)
            {
                const message = error instanceof Error ? error.message : String(error);
                if (warnings.get(target.id) !== message)
                    log(`${target.id}: ${message}`);

                warnings.set(target.id, message);
            }
        }
    }

    function refresh(): Promise<void>
    {
        refreshing ??= refreshWindows().finally(() =>
        {
            refreshing = undefined;
        });
        return refreshing;
    }

    async function detach(): Promise<unknown>
    {
        disabled = true;
        await refreshing?.catch(() => undefined);
        for (const session of sessions.values())
        {
            await session.evaluate("globalThis.__autonomCenter?.dispose();globalThis.__autonomShell?.dispose()").catch(() => undefined);
            await session.detach();
        }

        sessions.clear();
        windows.clear();
        warnings.clear();
        return { ok: true };
    }

    async function runScript(id: string, revision: string, windowId: number): Promise<unknown>
    {
        const session = windows.get(windowId);
        if (!session || disabled)
            throw new Error("The Desktop window is not attached.");

        const source = await loadAction(contentPath, content, id, revision, actionCache);
        const action = visibleItems(content).find((item) => item.id === id)?.actions?.left_click;
        if (source.type !== "js" || !action)
            throw new Error("The selected item is not a JS action.");

        const key = JSON.stringify(id);
        const version = JSON.stringify(action.version);
        if (!await session.evaluate(`globalThis.__autonomCenter?.hasScript(${key},${version})`))
            await session.evaluate(`globalThis.__autonomCenter.setScript(${key},${version},async (context) => {\n`
                + `${source.source}\n});`);

        await session.evaluate(`globalThis.__autonomCenter.runScript(${key},${version})`, 45000);
        return null;
    }

    function hot(): Promise<unknown>
    {
        if (stopping)
            return Promise.reject(new Error("The launcher is stopping."));

        reloading ??= reloadUi().finally(() =>
        {
            reloading = undefined;
        });
        return reloading;
    }

    async function reloadUi(): Promise<unknown>
    {
        const path = settings.commandCenterConfig;
        const next = await loadCenter(path);
        const source = await readFile(runtimePath, "utf8");
        await refreshing?.catch(() => undefined);
        if (stopping)
            throw new Error("The launcher is stopping.");

        for (const session of sessions.values())
        {
            const current = await status(session);
            const selected = visibleItems(next).find((item) => item.id === current?.activeItem);
            if (current?.mode === "autonom" && selected?.actions?.left_click.type === "html")
                await loadAction(path, next, selected.id, next.revision!, actionCache);
        }

        const replaced = source !== runtimeSource;
        contentPath = path;
        content = next;
        runtimeSource = source;
        disabled = false;
        const versions = new Map(visibleItems(content).filter((item) => item.actions)
            .map((item) => [resolve(dirname(contentPath), item.actions!.left_click.file), item.actions!.left_click.version]));
        for (const [file, cached] of actionCache)
            if (versions.get(file) !== cached.version)
                actionCache.delete(file);

        for (const session of sessions.values())
        {
            if (replaced)
                await install(session);
            else
                await session.evaluate(`globalThis.__autonomCenter.update(${JSON.stringify({
                    content, bridge: { url: bridge.url, token: bridge.token },
                })})`, 45000);
        }

        watchAssets();
        await refresh();
        return report();
    }

    function watchAssets(): void
    {
        if (stopping)
            return;

        watcher?.close();
        watcher = watch(dirname(contentPath), { recursive: true }, (_event, filename) =>
        {
            if (stopping || disabled)
                return;

            if (filename && ![".yml", ".html", ".js", ".css"].includes(extname(String(filename))))
                return;

            clearTimeout(reloadTimer);
            reloadTimer = setTimeout(() =>
            {
                if (!stopping && !disabled)
                    void hot().catch((error) => log(`UI reload rejected: ${error.message}`));
            }, 75);
        });
        watcher.on("error", (error) => log(`UI watcher: ${error.message}`));
    }

    async function report(): Promise<unknown>
    {
        const ret = [];
        for (const [targetId, session] of sessions)
            ret.push({ targetId, status: await status(session), error: warnings.get(targetId) ?? null });

        return { windows: ret };
    }

    async function shutdown(code: number): Promise<void>
    {
        if (stopping)
            return;

        stopping = true;
        clearTimeout(heartbeat);
        clearTimeout(reloadTimer);
        watcher?.close();
        await reloading?.catch(() => undefined);
        await detach();
        await control?.close();
        await bridge.close();
        cdp.close();
        transport.close();
        if (code && child?.exitCode === null)
            child.kill();

        process.exit(code);
    }

    async function tick(): Promise<void>
    {
        try
        {
            await refresh();
        }
        catch (error)
        {
            log(error instanceof Error ? error.message : String(error));
        }

        if (!stopping)
            heartbeat = setTimeout(() => void tick(), HEARTBEAT_INTERVAL);
    }

    process.on("SIGINT", () => void shutdown(0));
    process.on("SIGTERM", () => void shutdown(0));
    child?.on("error", (error) =>
    {
        log(error.message);
        void shutdown(1);
    });
    child?.on("exit", (code) =>
    {
        if (!foundWindow)
            log("Desktop forwarded this launch to an existing process without a debugging pipe. "
                + "Restart your normal Desktop profile through the launcher.");

        void shutdown(foundWindow ? (code ?? 0) : 1);
    });
    try
    {
        if (options.debugPort !== undefined)
        {
            const info = await cdp.request("SystemInfo.getProcessInfo");
            const processes = Array.isArray(info.processInfo) ? info.processInfo : [];
            if (child && !processes.some((entry) => entry.type === "browser" && entry.id === child.pid))
                throw new Error("The debug endpoint belongs to a different Desktop process; refusing to attach.");

            log(`DEBUG: CDP listens on 127.0.0.1:${options.debugPort}; quit Desktop to close this endpoint.`);
        }

        control = await startControlSocket(socketPath, {
            cdp,
            workbenchUrl: workbenchUrl(appRoot),
            status: report,
            hot,
            detach,
        });
        watchAssets();
        log(`Workspace ${process.cwd()}`);
        log(`Control socket ${socketPath}`);
        const deadline = Date.now() + ATTACH_TIMEOUT;
        while (!foundWindow && !stopping)
        {
            if (Date.now() > deadline)
                throw new Error("Timed out waiting for a Desktop window. Inspect targets through the control socket.");

            await refresh();
            if (!foundWindow)
                await new Promise((resolve_) => setTimeout(resolve_, 1000));
        }

        void tick();
    }
    catch (error)
    {
        log(error instanceof Error ? error.message : String(error));
        await shutdown(1);
    }
}

function parseArguments(argv: string[]): Options
{
    const ret: Options = { arguments: [], debugPort: undefined };
    for (const argument of argv)
    {
        if (argument === "--debug")
            ret.debugPort = 9222;
        else if (argument.startsWith("--debug="))
            ret.debugPort = port(argument.slice("--debug=".length));
        else
            ret.arguments.push(argument);
    }

    return ret;
}

function port(value: string): number
{
    const ret = Number(value);
    if (!Number.isInteger(ret) || ret < 1 || ret > 65535)
        throw new Error("The port must be an integer between 1 and 65535.");

    return ret;
}

function environmentPort(): number | undefined
{
    const value = process.env.AUTONOM_PORT;
    return value?.trim() ? port(value) : undefined;
}

function log(message: string): void
{
    process.stdout.write(`[autonom] ${message}\n`);
}

void main().catch((error: unknown) =>
{
    log(error instanceof Error ? error.message : String(error));
    process.exit(1);
});
