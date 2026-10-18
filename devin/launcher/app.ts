import { acpRegistryIcons, ensureAcpAgent } from "./acp/registry";
import type { CdpSession } from "./cdp/client";
import { CdpClient } from "./cdp/client";
import { defaultSocketPath, isLauncherRunning, startControlSocket } from "./cdp/control";
import { startBridge } from "./center/bridge";
import type { ActionCache } from "./center/config";
import { loadAction, loadCenter } from "./center/config";
import { declaredItems, visibleItems } from "./center/content";
import { watchContent } from "./center/watch";
import { executeScript, installRuntime, runtimeStatus } from "./center/window";
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
    await verifyDesktopBuild(appRoot);
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
    const sessions = new Map<string, CdpSession>();
    const windows = new Map<number, CdpSession>();
    const warnings = new Map<string, string>();
    let control: { close(): Promise<void> } | undefined;
    let heartbeat: ReturnType<typeof setTimeout> | undefined;
    let disabled = false;
    let stopping = false;
    let refreshing: Promise<void> | undefined;
    let foundWindow = false;
    let watcher: { close(): void } | undefined;
    let reloading: Promise<unknown> | undefined;

    async function install(session: CdpSession): Promise<void>
    {
        const current = await installRuntime(session, runtimeSource, {
            content, bridge: { url: bridge.url, token: bridge.token },
        });
        if (current)
        {
            windows.set(current.windowId, session);
        }

        log(`Attached ${session.targetId}: ${current?.mode}, active ${current?.activeItem ?? "none"}`);
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

        const icons = JSON.stringify(await acpRegistryIcons().catch(() => ({})));

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
                    const shell = globalThis.__autonomShell;
                    if (!shell) {
                        ${runtimeSource}
                        AutonomRuntime.prepareShell(${JSON.stringify(content.css)}, ${icons});
                    } else {
                        shell.update(${JSON.stringify(content.css)}, ${icons});
                        shell.heartbeat();
                    }
                })()`);
                if (!await runtimeStatus(session))
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
        await refreshing?.catch(() => undefined);
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
        const versions = new Map(declaredItems(content).filter((item) => item.actions)
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
        watcher = watchContent(dirname(contentPath), () =>
        {
            if (!stopping && !disabled)
                void hot().catch((error) => log(`UI reload rejected: ${error.message}`));
        }, (error) => log(`UI watcher: ${error.message}`));
    }

    async function report(): Promise<unknown>
    {
        const ret = [];
        for (const [targetId, session] of sessions)
            ret.push({ targetId, status: await runtimeStatus(session), error: warnings.get(targetId) ?? null });

        return { windows: ret };
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
            heartbeat = setTimeout(() => void tick(), heartbeatInterval);
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
        const deadline = Date.now() + attachTimeout;
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

function log(message: string): void
{
    process.stdout.write(`[autonom] ${message}\n`);
}

void main().catch((error: unknown) =>
{
    log(error instanceof Error ? error.message : String(error));
    process.exit(1);
});
