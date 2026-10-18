import { ensureAcpAgent } from "./acp/registry";
import { CdpClient } from "./cdp/client";
import { defaultSocketPath, isLauncherRunning, startControlSocket } from "./cdp/control";
import { startBridge } from "./center/bridge";
import type { ActionCache } from "./center/config";
import { loadAction, loadCenter } from "./center/config";
import { declaredItems, visibleItems } from "./center/content";
import { watchContent } from "./center/watch";
import { executeScript, runtimeStatus } from "./patches/window";
import { Windows } from "./center/windows";
import { installerStatus } from "./patches/installer";
import { environmentPort, parseArguments } from "./cli";
import type { LauncherSettings } from "./config";
import { defaultDaemonConfigPath, defaultSettingsPath, expandPath, readSettings } from "./config";
import { DaemonClient } from "./daemon/client";
import { readDaemonConfig } from "./daemon/config";
import { verifyDesktopBuild } from "./desktop/build";
import { appRootFor, launchDesktop, openInDesktop, resolveDesktopBinary, workbenchUrl } from "./desktop/process";

import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

const heartbeatInterval = 5000;
const attachTimeout = 60000;

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
    const build = await verifyDesktopBuild(appRoot);
    const installer = await installerStatus(repository, appRoot, build);
    log(`Patch ${JSON.stringify(installer)}`);
    try
    {
        const daemonConfig = await readDaemonConfig(settings.configFile);
        const acpArguments = ["--config", settings.configFile];
        if (typeof daemonConfig.devinCommand === "string" && daemonConfig.devinCommand)
            acpArguments.push("--devin", daemonConfig.devinCommand);
        await ensureAcpAgent({ command: join(repository, "bin", "autonom-acp"), args: acpArguments });
    }
    catch (error)
    {
        log(`ACP registration skipped: ${error instanceof Error ? error.message : String(error)}`);
    }
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
    const attached = new Windows(cdp, [
        workbenchUrl(appRoot),
        `vscode-file://vscode-app${join(appRoot, "out/vs/sessions/electron-browser/sessions.html")}`,
    ], () => ({ source: runtimeSource, config: {
        content, bridge: { url: bridge.url, token: bridge.token },
    } }), log);
    const sessions = attached.sessions;
    const windows = attached.byId;
    let control: { close(): Promise<void> } | undefined;
    let heartbeat: ReturnType<typeof setTimeout> | undefined;
    let disabled = false;
    let stopping = false;
    let watcher: { close(): void } | undefined;
    let reloading: Promise<unknown> | undefined;

    function refresh(): Promise<void>
    {
        return disabled || stopping ? Promise.resolve() : attached.refresh();
    }

    async function detach(): Promise<unknown>
    {
        disabled = true;
        await attached.detach();
        return { ok: true };
    }

    async function runScript(id: string, revision: string, windowId: number): Promise<unknown>
    {
        const session = windows.get(windowId);
        if (!session || disabled)
            throw new Error("The Desktop window is not attached.");

        const source = await loadAction(contentPath, content, id, revision, actionCache);
        const action = declaredItems(content).find((item) => item.id === id)?.actions?.left_click;
        if (source.type !== "js" || !action)
            throw new Error("The selected item is not a JS action.");

        await executeScript(session, id, action.version, source.source);
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
        await attached.settled();
        if (stopping)
            throw new Error("The launcher is stopping.");

        for (const session of sessions.values())
        {
            const current = await runtimeStatus(session);
            const selected = visibleItems(next).find((item) => item.id === current?.activeItem);
            if (current?.mode === "autonom" && selected?.actions?.left_click.type === "html")
                await loadAction(path, next, selected.id, next.revision!, actionCache);
        }

        const replaced = source !== runtimeSource;
        contentPath = path;
        content = next;
        runtimeSource = source;
        disabled = false;
        attached.disabled = false;
        const versions = new Map(declaredItems(content).filter((item) => item.actions)
            .map((item) => [resolve(dirname(contentPath), item.actions!.left_click.file), item.actions!.left_click.version]));
        for (const [file, cached] of actionCache)
            if (versions.get(file) !== cached.version)
                actionCache.delete(file);

        for (const session of sessions.values())
        {
            if (replaced)
                await attached.install(session);
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
        watcher = watchContent(dirname(contentPath), () =>
        {
            if (!stopping && !disabled)
                void hot().catch((error) => log(`UI reload rejected: ${error.message}`));
        }, (error) => log(`UI watcher: ${error.message}`));
    }

    async function report(): Promise<unknown>
    {
        return { ...await attached.report(), installer };
    }

    async function shutdown(code: number): Promise<void>
    {
        if (stopping)
            return;

        stopping = true;
        clearTimeout(heartbeat);
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
            heartbeat = setTimeout(() => void tick(), attached.pending ? 100 : heartbeatInterval);
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
        if (!attached.found)
            log("Desktop forwarded this launch to an existing process without a debugging pipe. "
                + "Restart your normal Desktop profile through the launcher.");

        void shutdown(attached.found ? (code ?? 0) : 1);
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
        await attached.start();
        watchAssets();
        log(`Workspace ${process.cwd()}`);
        log(`Control socket ${socketPath}`);
        const deadline = Date.now() + attachTimeout;
        while (!attached.found && !stopping)
        {
            if (Date.now() > deadline)
                throw new Error("Timed out waiting for a Desktop window. Inspect targets through the control socket.");

            await refresh();
            if (!attached.found)
                await new Promise((resolve_) => setTimeout(resolve_, 100));
        }

        void tick();
    }
    catch (error)
    {
        log(error instanceof Error ? error.message : String(error));
        await shutdown(1);
    }
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
