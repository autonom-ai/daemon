import { ensureDefaultConfig, readRouterKey } from "./config";
import { object, text } from "./config";

import { spawn } from "node:child_process";
import { constants } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { createConnection } from "node:net";
import { isAbsolute, join, resolve } from "node:path";

const MAX_RESPONSE_BYTES = 6 * 1024 * 1024;

export type Health = {
    configFile: string;
    controlFile: string;
    pid: number;
    workerPid: number;
};

export type DaemonSettings = {
    port: number;
    configFile: string;
    rootDirectory: string;
};

export class DaemonClient
{
    private settings: DaemonSettings;
    private token = "";
    private connection: Promise<Health> | undefined;
    private health: Health | undefined;

    constructor(settings: DaemonSettings)
    {
        this.settings = settings;
    }

    configure(settings: DaemonSettings): void
    {
        if (settings.port !== this.settings.port || settings.rootDirectory !== this.settings.rootDirectory
            || settings.configFile !== this.settings.configFile)
        {
            this.token = "";
            this.health = undefined;
            this.connection = undefined;
        }
        this.settings = settings;
    }

    async connect(): Promise<Health>
    {
        if (this.connection !== undefined)
            return this.connection;
        const ret = this.ensure().finally(() =>
        {
            this.connection = undefined;
        });
        this.connection = ret;
        return ret;
    }

    async request<Result>(path: string, method = "GET", body?: unknown): Promise<Result>
    {
        if (!path.startsWith("/api/") || path.includes("#"))
            throw new Error("Invalid Autonom API path.");
        if (!this.token)
            await this.connect();
        let response: Response;
        try
        {
            response = await fetch(this.base + path, {
                method,
                headers: { "content-type": "application/json", "x-autonom-client": this.token },
                ...(body === undefined ? {} : { body: JSON.stringify(body) }),
                signal: AbortSignal.timeout(15000),
            });
        }
        catch
        {
            this.token = "";
            throw new Error("Autonom is unavailable. Use Refresh to reconnect.");
        }
        const value = await responseJson(response);
        if (!response.ok)
        {
            if (response.status === 403)
                this.token = "";
            throw new Error(text(object(value)?.error, `Autonom returned HTTP ${response.status}.`));
        }
        return value as Result;
    }

    get configurationPath(): string
    {
        return this.health?.configFile || this.settings.configFile;
    }

    async getState(directory?: string): Promise<unknown>
    {
        const query = directory ? `?directory=${encodeURIComponent(directory)}` : "";
        return this.request(`/api/client/state${query}`);
    }

    async manageSession(id: string): Promise<unknown>
    {
        return this.request(`/api/sessions/${encodeURIComponent(id)}/manage`, "POST", {});
    }

    private get base(): string
    {
        return `http://127.0.0.1:${this.settings.port}`;
    }

    private async ensure(): Promise<Health>
    {
        let health = await this.probe();
        if (health === undefined)
        {
            if (await isPortInUse(this.settings.port))
                throw new Error(`Port ${this.settings.port} is already in use by another service. Change the port in the Command Center settings or stop the conflicting service.`);
            const root = this.settings.rootDirectory;
            if (!isAbsolute(root))
                throw new Error("The Autonom repository path is not absolute.");
            const bootstrap = join(root, "source", "mcp", "server.py");
            const attributes = await lstat(bootstrap).catch(() => undefined);
            if (!attributes?.isFile() || attributes.isSymbolicLink())
                throw new Error("The repository does not contain the Autonom MCP server.");
            const binary = join(root, "bin", "autonom-daemon");
            const binaryAttr = await lstat(binary).catch(() => undefined);
            if (!binaryAttr?.isFile())
                throw new Error("The Autonom daemon is not built. Run 'dub build --compiler=ldc2' in the Autonom repository.");
            if (this.settings.configFile)
            {
                await ensureDefaultConfig(this.settings.configFile);
                const routerKey = await readRouterKey(this.settings.configFile);
                if (!routerKey)
                    throw new Error(`OpenRouter API key is not configured. Set router.key in ${this.settings.configFile}.`);
            }
            await startDaemon(root, this.settings);
            health = await this.probe();
        }
        if (health === undefined)
            throw new Error("Autonom did not become ready. Check its daemon log and configuration.");
        if (this.settings.configFile && resolve(health.configFile) !== resolve(this.settings.configFile))
            throw new Error("The daemon on this port uses a different config file. Match the path or choose another port.");
        this.token = await readCapability(health.controlFile);
        this.health = health;
        return health;
    }

    private async probe(): Promise<Health | undefined>
    {
        try
        {
            const response = await fetch(this.base + "/api/health", { signal: AbortSignal.timeout(1500) });
            const value = object(await responseJson(response));
            if (!response.ok || value?.status !== "ok" || !isAbsolute(text(value.controlFile))
                || !isAbsolute(text(value.configFile)) || typeof value.pid !== "number")
                return undefined;
            return {
                configFile: text(value.configFile),
                controlFile: text(value.controlFile),
                pid: value.pid,
                workerPid: Number(value.workerPid),
            };
        }
        catch
        {
            return undefined;
        }
    }
}

export async function readCapability(path: string): Promise<string>
{
    const descriptor = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try
    {
        const attributes = await descriptor.stat();
        if (!attributes.isFile() || attributes.size > 128 || (attributes.mode & 0o077) !== 0
            || (process.getuid !== undefined && attributes.uid !== process.getuid()))
            throw new Error("Autonom client capability is not a private, user-owned regular file.");
        const ret = (await descriptor.readFile("utf8")).trim();
        if (!/^[a-f0-9]{64}$/.test(ret))
            throw new Error("Autonom returned an invalid client capability.");
        return ret;
    }
    finally
    {
        await descriptor.close();
    }
}

async function responseJson(response: Response): Promise<unknown>
{
    const reader = response.body?.getReader();
    if (reader === undefined)
        throw new Error("Autonom returned an empty response.");
    const chunks: Uint8Array[] = [];
    let bytes = 0;
    try
    {
        while (true)
        {
            const result = await reader.read();
            if (result.done)
                break;
            bytes += result.value.byteLength;
            if (bytes > MAX_RESPONSE_BYTES)
                throw new Error("Autonom response exceeds the display limit.");
            chunks.push(result.value);
        }
        return JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
    }
    finally
    {
        await reader.cancel().catch(() => undefined);
    }
}

async function startDaemon(root: string, settings: DaemonSettings): Promise<void>
{
    const environment: NodeJS.ProcessEnv = { ...process.env, AUTONOM_PORT: String(settings.port) };
    if (settings.configFile)
        environment.AUTONOM_CONFIG = settings.configFile;
    delete environment.AUTONOM_RUN_TOKEN;
    delete environment.AUTONOM_CLIENT_TOKEN;
    await new Promise<void>((resolve_, reject) =>
    {
        const child = spawn("python3", [join(root, "source", "mcp", "server.py"), "--ensure"], {
            cwd: root,
            env: environment,
            stdio: ["ignore", "pipe", "pipe"],
            timeout: 25000,
        });
        let bytes = 0;
        child.stdout.on("data", (chunk: Buffer) =>
        {
            bytes += chunk.length;
            if (bytes > 65536)
                child.kill();
        });
        let stderr = "";
        child.stderr.on("data", (chunk: Buffer) =>
        {
            if (stderr.length < 4096)
                stderr += chunk.toString("utf8");
        });
        child.on("error", (error: NodeJS.ErrnoException) =>
        {
            if (error.code === "ENOENT")
                reject(new Error("Python 3 is required to start Autonom. Install python3 and ensure it is available in PATH."));
            else
                reject(new Error(`Could not run Python to start Autonom: ${error.message}`));
        });
        child.on("close", (code) =>
        {
            if (code === 0)
                resolve_();
            else
            {
                const detail = stderr.trim();
                if (detail.includes("The autonom daemon is not built"))
                    reject(new Error("The Autonom daemon is not built. Run 'dub build --compiler=ldc2' in the Autonom repository."));
                else if (detail)
                    reject(new Error(`Autonom startup failed: ${detail}`));
                else
                    reject(new Error("Autonom startup failed. Check the daemon log and configured paths."));
            }
        });
    });
}

function isPortInUse(port: number): Promise<boolean>
{
    return new Promise((resolve_) =>
    {
        const socket = createConnection({ host: "127.0.0.1", port }, () =>
        {
            socket.destroy();
            resolve_(true);
        });
        socket.on("error", () => resolve_(false));
        socket.setTimeout(500, () =>
        {
            socket.destroy();
            resolve_(false);
        });
    });
}
