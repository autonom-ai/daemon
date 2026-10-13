import { probe, SERVICE_CAPTURE } from "./boundary";
import type { Bridge } from "./bridge";
import { startBridge } from "./bridge";
import { captureInvocation, CdpClient } from "./cdp";
import type { CdpSession } from "./cdp";
import { loadCenter } from "./center";
import { DaemonClient } from "./client";
import type { LauncherSettings } from "./config";
import { defaultDaemonConfigPath, defaultSettingsPath, expandPath, readSettings } from "./config";
import type { CenterContent } from "./content";
import { defaultSocketPath, startControlSocket } from "./control";
import { appRootFor, launchDesktop, openInDesktop, resolveDesktopBinary, verifyDesktopBuild, workbenchUrl } from "./desktop";
import { object, text } from "./parse";
import type { RuntimeStatus } from "./runtime";

import type { ChildProcess } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const HEARTBEAT_INTERVAL = 5000;
const ATTACH_INTERVAL = 1000;
const ATTACH_TIMEOUT = 60000;
const DEFAULT_PORT = 8080;

const USAGE = `Usage: autonom-launcher [workspace] [options]

Launches Devin Desktop with --remote-debugging-pipe and attaches the Autonom Command Center.

Options:
  --desktop <command>      Devin Desktop command (default: devin-desktop)
  --config <file>          Command Center definition (default: <repository>/assets/commandCenter.json)
  --daemon-config <file>   Daemon configuration (default: ~/.config/autonom/config.yml)
  --port <port>            Daemon loopback port (default: 8080 or AUTONOM_PORT)
  --socket <path>          Control socket (default: $XDG_RUNTIME_DIR/autonom/launcher.sock)
  --help                   Show this help
`;

type Options = {
    workspace: string;
    desktop: string;
    config: string | undefined;
    daemonConfig: string | undefined;
    port: number | undefined;
    socket: string;
    help: boolean;
};

class DesktopCenter
{
    private readonly sessions = new Map<string, CdpSession>();
    private readonly statuses = new Map<string, RuntimeStatus>();
    private content: CenterContent;
    private runtimeSource: string;
    private lastWarning = "";
    private disabled = false;

    constructor(private readonly options: {
        cdp: CdpClient;
        appRoot: string;
        configPath: string;
        runtimePath: string;
        runtimeSource: string;
        bridge: Bridge;
        content: CenterContent;
    })
    {
        this.content = options.content;
        this.runtimeSource = options.runtimeSource;
    }

    async refresh(): Promise<void>
    {
        if (this.disabled)
            return;
        const url = workbenchUrl(this.options.appRoot);
        const targets = (await this.options.cdp.targets())
            .filter((target) => target.type === "page" && target.url === url);
        for (const target of targets)
        {
            try
            {
                const session = await this.session(target.id);
                if (await this.status(session) === null)
                    log(`Attached the Command Center: ${summarize(await this.install(session))}`);
            }
            catch (error)
            {
                this.warn(error);
            }
        }
        for (const [id, session] of [...this.sessions])
        {
            if (targets.some((target) => target.id === id))
                continue;
            this.sessions.delete(id);
            this.statuses.delete(id);
            await session.detach();
        }
    }

    async hot(): Promise<unknown>
    {
        this.content = await loadCenter(this.options.configPath);
        this.runtimeSource = await readFile(this.options.runtimePath, "utf8");
        const ret = [];
        for (const [targetId, session] of this.sessions)
            ret.push({ targetId, status: summarize(await this.install(session)) });
        return ret;
    }

    async detach(): Promise<unknown>
    {
        this.disabled = true;
        for (const session of this.sessions.values())
        {
            await session.evaluate("globalThis.__autonomCenter?.dispose()").catch(() => undefined);
            await session.detach();
        }
        this.sessions.clear();
        this.statuses.clear();
        return { ok: true };
    }

    async report(): Promise<unknown>
    {
        const windows = [];
        for (const [targetId, session] of this.sessions)
        {
            windows.push({
                targetId,
                status: this.statuses.get(targetId) ?? await this.status(session).catch(() => null),
            });
        }
        return { windows };
    }

    private async session(targetId: string): Promise<CdpSession>
    {
        let session = this.sessions.get(targetId);
        if (!session)
        {
            session = await this.options.cdp.attach(targetId);
            this.sessions.set(targetId, session);
        }
        return session;
    }

    private async status(session: CdpSession): Promise<RuntimeStatus | null>
    {
        const value = await session.evaluate(statusProjection("(function(){const runtime=globalThis.__autonomCenter;"
            + "if(!runtime)return null;runtime.heartbeat();return runtime.status();})()"));
        if (value === null || value === undefined)
            return null;
        const status = validateStatus(value);
        this.statuses.set(session.targetId, status);
        return status;
    }

    private async install(session: CdpSession): Promise<RuntimeStatus>
    {
        const found = await session.evaluate(`globalThis.__autonomAttachProbe=(${probe.toString()})();`
            + "Boolean(globalThis.__autonomAttachProbe)");
        if (found !== true)
            throw new Error("The Devin agent window is not showing. Open it in Devin Desktop (Ctrl+') and the Command Center attaches automatically.");
        try
        {
            await session.request("Debugger.enable", { maxScriptsCacheSize: 0 });
            try
            {
                for (const capture of SERVICE_CAPTURE)
                    await captureInvocation(session, `globalThis.__autonomAttachProbe.props.${capture.name}`, capture.assignments);
            }
            finally
            {
                await session.request("Debugger.disable").catch(() => undefined);
            }
            const config = { content: this.content, bridge: { url: this.options.bridge.url, token: this.options.bridge.token } };
            const value = await session.evaluate(statusProjection(`${this.runtimeSource};`
                + `AutonomRuntime.install(globalThis.__autonomServices,${JSON.stringify(config)}).update(${JSON.stringify(config)})`));
            if (value === null || value === undefined)
                throw new Error("The Command Center runtime did not report a status.");
            const status = validateStatus(value);
            this.statuses.set(session.targetId, status);
            return status;
        }
        finally
        {
            await session.evaluate("delete globalThis.__autonomAttachProbe;delete globalThis.__autonomServices;")
                .catch(() => undefined);
        }
    }

    private warn(error: unknown): void
    {
        const message = error instanceof Error ? error.message : String(error);
        if (message === this.lastWarning)
            return;
        this.lastWarning = message;
        log(message);
    }
}

async function main(): Promise<void>
{
    const options = parseArguments(process.argv.slice(2));
    if (options.help)
    {
        process.stdout.write(USAGE);
        return;
    }
    const repository = resolve(__dirname, "..", "..", "..");
    const settingsPath = defaultSettingsPath();
    const stored = await loadSettings(settingsPath);
    const settings: LauncherSettings = {
        port: options.port ?? environmentPort() ?? stored.port ?? DEFAULT_PORT,
        configFile: expandPath(options.daemonConfig ?? process.env.AUTONOM_CONFIG ?? stored.configFile ?? defaultDaemonConfigPath()),
        commandCenterConfig: expandPath(options.config ?? stored.commandCenterConfig ?? join(repository, "assets", "commandCenter.json")),
    };
    const binary = resolveDesktopBinary(options.desktop);
    const appRoot = appRootFor(binary);
    await verifyDesktopBuild(appRoot);
    const content = await loadCenter(settings.commandCenterConfig);
    const client = new DaemonClient({ port: settings.port, configFile: settings.configFile, rootDirectory: repository });
    const bridge = await startBridge({
        workspace: options.workspace,
        repository,
        settingsPath,
        settings,
        client,
        openPath: (path) => openInDesktop(options.desktop, path),
    });
    const runtimePath = join(__dirname, "runtime.js");
    const { child, transport } = launchDesktop({ binary, workspace: options.workspace });
    const cdp = new CdpClient(transport);
    const center = new DesktopCenter({
        cdp,
        appRoot,
        configPath: settings.commandCenterConfig,
        runtimePath,
        runtimeSource: await readFile(runtimePath, "utf8"),
        bridge,
        content,
    });
    log(`Workspace ${options.workspace}`);
    log(`Daemon port ${settings.port}, configuration ${settings.configFile}`);
    log(`Command Center ${settings.commandCenterConfig}`);
    let heartbeat: ReturnType<typeof setInterval> | undefined;
    let control: { close: () => Promise<void> } | undefined;
    let stopping = false;
    const shutdown = async (code: number): Promise<void> =>
    {
        if (stopping)
            return;
        stopping = true;
        clearInterval(heartbeat);
        await center.detach().catch(() => undefined);
        await control?.close().catch(() => undefined);
        await bridge.close().catch(() => undefined);
        cdp.close();
        process.exit(code);
    };
    process.on("SIGINT", () =>
    {
        void shutdown(0);
    });
    process.on("SIGTERM", () =>
    {
        void shutdown(0);
    });
    child.on("exit", (code) =>
    {
        log("Devin Desktop exited.");
        void shutdown(code ?? 0);
    });
    try
    {
        await waitForWindow(child, cdp, appRoot);
        await center.refresh();
        heartbeat = setInterval(() =>
        {
            void center.refresh().catch((error) =>
            {
                log(error instanceof Error ? error.message : String(error));
            });
        }, HEARTBEAT_INTERVAL);
        control = await startControlSocket(options.socket, {
            cdp,
            workbenchUrl: workbenchUrl(appRoot),
            status: () => center.report(),
            hot: () => center.hot(),
            detach: () => center.detach(),
        });
        log(`Control socket ${options.socket}`);
    }
    catch (error)
    {
        process.stderr.write(`[autonom] ${error instanceof Error ? error.message : String(error)}\n`);
        await shutdown(1);
    }
}

async function waitForWindow(child: ChildProcess, cdp: CdpClient, appRoot: string): Promise<void>
{
    const url = workbenchUrl(appRoot);
    const deadline = Date.now() + ATTACH_TIMEOUT;
    let exited = false;
    child.once("exit", () =>
    {
        exited = true;
    });
    while (Date.now() < deadline)
    {
        if (exited)
            throw new Error("Devin Desktop exited before the Command Center attached. Quit any running Devin Desktop window and launch again.");
        try
        {
            const targets = await cdp.targets();
            if (targets.some((target) => target.type === "page" && target.url === url))
                return;
        }
        catch
        {
        }
        await delay(ATTACH_INTERVAL);
    }
    throw new Error("Timed out waiting for the Devin Desktop workbench window.");
}

function parseArguments(argv: string[]): Options
{
    const ret: Options = {
        workspace: process.cwd(),
        desktop: "devin-desktop",
        config: undefined,
        daemonConfig: undefined,
        port: undefined,
        socket: defaultSocketPath(),
        help: false,
    };
    for (let index = 0; index < argv.length; index++)
    {
        const argument = argv[index]!;
        const value = (): string =>
        {
            const next = argv[++index];
            if (next === undefined)
                throw new Error(`Missing value for ${argument}.`);
            return next;
        };
        switch (argument)
        {
            case "--help":
            case "-h":
                ret.help = true;
                break;
            case "--desktop":
                ret.desktop = value();
                break;
            case "--config":
                ret.config = value();
                break;
            case "--daemon-config":
                ret.daemonConfig = value();
                break;
            case "--port":
                ret.port = port(value(), argument);
                break;
            case "--socket":
                ret.socket = expandPath(value());
                break;
            default:
                if (argument.startsWith("-"))
                    throw new Error(`Unknown option: ${argument}`);
                ret.workspace = resolve(argument);
                break;
        }
    }
    return ret;
}

function port(value: string, source: string): number
{
    const ret = Number(value);
    if (!Number.isInteger(ret) || ret < 1 || ret > 65535)
        throw new Error(`${source} requires an integer between 1 and 65535.`);
    return ret;
}

function environmentPort(): number | undefined
{
    const value = process.env.AUTONOM_PORT;
    return value === undefined || !value.trim() ? undefined : port(value, "AUTONOM_PORT");
}

async function loadSettings(path: string): Promise<Partial<LauncherSettings>>
{
    try
    {
        return await readSettings(path);
    }
    catch (error)
    {
        if ((error as NodeJS.ErrnoException).code === "ENOENT")
            return {};
        throw error;
    }
}

function statusProjection(expression: string): string
{
    return `(async()=>{const ret=await (${expression});if(!ret)return null;return {connected:ret.connected,`
        + "mode:ret.mode,enabled:ret.enabled,revision:ret.revision,activeTab:ret.activeTab,windowId:ret.windowId,"
        + "items:ret.items.map((item)=>({id:item.id,label:item.label,path:item.path}))};})()";
}

function validateStatus(value: unknown): RuntimeStatus
{
    const ret = object(value);
    if (ret === undefined || typeof ret.connected !== "boolean" || typeof ret.enabled !== "boolean"
        || (ret.mode !== "autonom" && ret.mode !== "devin-cloud")
        || (ret.revision !== null && typeof ret.revision !== "string")
        || (ret.activeTab !== null && typeof ret.activeTab !== "string")
        || !Number.isSafeInteger(ret.windowId) || !Array.isArray(ret.items) || ret.items.length > 512)
        throw new Error("The Command Center runtime returned an invalid status.");
    return {
        connected: ret.connected,
        mode: ret.mode,
        enabled: ret.enabled,
        revision: typeof ret.revision === "string" ? ret.revision : null,
        activeTab: typeof ret.activeTab === "string" ? ret.activeTab : null,
        windowId: ret.windowId as number,
        items: ret.items.map((item) =>
        {
            const entry = object(item) ?? {};
            return { id: text(entry.id), label: text(entry.label), path: text(entry.path) };
        }),
    };
}

function summarize(status: RuntimeStatus): string
{
    return `${status.mode}, revision ${status.revision?.slice(0, 12) ?? "none"}, active ${status.activeTab ?? "none"}, `
        + `${status.items.length} items`;
}

function log(message: string): void
{
    process.stdout.write(`[autonom] ${message}\n`);
}

function delay(milliseconds: number): Promise<void>
{
    return new Promise((resolve_) =>
    {
        setTimeout(resolve_, milliseconds);
    });
}

void main().catch((error: unknown) =>
{
    process.stderr.write(`[autonom] ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
});
