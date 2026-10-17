import type { ChildProcess } from "node:child_process";
import { spawn } from "node:child_process";
import { closeSync, constants, openSync, readSync, realpathSync, statSync } from "node:fs";
import { createServer } from "node:net";
import { basename, delimiter, dirname, isAbsolute, join, resolve } from "node:path";
import type { Readable, Writable } from "node:stream";
import { pathToFileURL } from "node:url";

export { DESKTOP_COMMIT, DESKTOP_VERSION, verifyDesktopBuild, WORKBENCH_HASH } from "./build";

const MAX_PIPE_MESSAGE_BYTES = 32 * 1024 * 1024;
const ENVIRONMENT_PREFIXES = [
    "ACP_",
    "ELECTRON_",
    "VSCODE_",
    "WINDSURF_",
    "AUTONOM_CLIENT_",
    "AUTONOM_RUN_",
    "AUTONOM_MCP_",
    "AUTONOM_RELAY_",
    "OPENROUTER_API_KEY",
];

export type CdpTransport = {
    send(message: unknown): void;
    onMessage(listener: (message: unknown) => void): () => void;
    onClose(listener: () => void): () => void;
    close(): void;
};

export class PipeTransport
{
    private buffer = Buffer.alloc(0);
    private readonly listeners = new Set<(message: unknown) => void>();
    private readonly closeListeners = new Set<() => void>();
    private closed = false;

    constructor(private readonly readable: Readable, private readonly writable: Writable)
    {
        readable.on("data", (chunk: Buffer) =>
        {
            this.receive(chunk);
        });
        readable.on("error", () =>
        {
            this.close();
        });
        readable.on("close", () =>
        {
            this.close();
        });
        writable.on("error", () =>
        {
            this.close();
        });
        writable.on("close", () =>
        {
            this.close();
        });
    }

    send(message: unknown): void
    {
        if (this.closed || this.writable.destroyed)
            throw new Error("The Desktop debugging pipe is closed.");
        this.writable.write(`${JSON.stringify(message)}\0`);
    }

    onMessage(listener: (message: unknown) => void): () => void
    {
        this.listeners.add(listener);
        return () =>
        {
            this.listeners.delete(listener);
        };
    }

    onClose(listener: () => void): () => void
    {
        if (this.closed)
            listener();
        else
            this.closeListeners.add(listener);
        return () =>
        {
            this.closeListeners.delete(listener);
        };
    }

    close(): void
    {
        if (this.closed)
            return;
        this.closed = true;
        this.buffer = Buffer.alloc(0);
        this.listeners.clear();
        for (const listener of this.closeListeners)
            listener();
        this.closeListeners.clear();
        this.readable.destroy();
        this.writable.destroy();
    }

    private receive(chunk: Buffer): void
    {
        if (this.closed)
            return;
        this.buffer = Buffer.concat([this.buffer, chunk]);
        if (this.buffer.length > MAX_PIPE_MESSAGE_BYTES)
        {
            this.close();
            return;
        }
        let end = this.buffer.indexOf(0);
        while (end >= 0)
        {
            const message = this.buffer.subarray(0, end).toString("utf8");
            this.buffer = this.buffer.subarray(end + 1);
            end = this.buffer.indexOf(0);
            if (!message)
                continue;
            let parsed: unknown;
            try
            {
                parsed = JSON.parse(message);
            }
            catch
            {
                this.close();
                return;
            }
            for (const listener of this.listeners)
                listener(parsed);
        }
    }
}

export function resolveDesktopBinary(command: string): string
{
    const found = command.includes("/") || isAbsolute(command) ? resolve(command) : searchPath(command);
    if (found === undefined || !isExecutable(found))
        throw new Error(`Cannot find the Devin Desktop command '${command}'.`);
    const resolved = realpathSync(found);
    if (basename(dirname(resolved)) === "bin" && isShellScript(resolved))
    {
        const binary = join(dirname(dirname(resolved)), basename(resolved));
        if (!isExecutable(binary))
            throw new Error(`Cannot find the Devin Desktop binary beside ${resolved}.`);
        return binary;
    }
    return resolved;
}

export function appRootFor(binary: string): string
{
    return join(dirname(binary), "resources", "app");
}

export function workbenchUrl(appRoot: string): string
{
    const path = pathToFileURL(join(appRoot, "out/vs/code/electron-browser/workbench/workbench.html")).pathname;
    return `vscode-file://vscode-app${path}`;
}

export async function launchDesktop(options: {
    binary: string;
    arguments?: string[];
    debugPort?: number;
}): Promise<{ child: ChildProcess; transport: CdpTransport }>
{
    if (options.debugPort !== undefined)
    {
        const server = createServer();
        await new Promise<void>((resolve_, reject) =>
        {
            server.once("error", reject);
            server.listen(options.debugPort, "127.0.0.1", resolve_);
        });
        await new Promise<void>((resolve_) => server.close(() => resolve_()));
    }

    const flags = options.debugPort === undefined ? ["--remote-debugging-pipe"]
        : [`--remote-debugging-port=${options.debugPort}`, "--remote-debugging-address=127.0.0.1"];
    const child = spawn(options.binary, [...flags, ...(options.arguments ?? [])], {
        detached: false,
        stdio: options.debugPort === undefined ? ["ignore", "inherit", "inherit", "pipe", "pipe"] : "inherit",
        env: { ...cleanEnvironment(), VSCODE_CWD: process.cwd() },
    });
    let spawnError: Error | undefined;
    child.on("error", (error) =>
    {
        spawnError = error;
    });
    if (options.debugPort !== undefined)
    {
        try
        {
            const deadline = Date.now() + 15000;
            while (Date.now() < deadline)
            {
                if (spawnError)
                    throw spawnError;
                if (child.exitCode !== null || child.signalCode !== null)
                    throw new Error("Desktop exited before the debug endpoint opened. Restart the existing Desktop first.");

                let address: string | undefined;
                try
                {
                    const response = await fetch(`http://127.0.0.1:${options.debugPort}/json/version`, {
                        signal: AbortSignal.timeout(500), redirect: "error",
                    });
                    if (response.ok)
                        address = (await response.json() as { webSocketDebuggerUrl?: string }).webSocketDebuggerUrl;
                }
                catch
                {
                }

                if (address)
                    return { child, transport: await connectDebugTransport(address, options.debugPort) };

                await new Promise((resolve_) => setTimeout(resolve_, 100));
            }

            throw new Error("Timed out waiting for the loopback Desktop debug endpoint.");
        }
        catch (error)
        {
            if (child.exitCode === null)
                child.kill();

            throw error;
        }
    }

    const readable = child.stdio[4];
    const writable = child.stdio[3];
    if (!readable || !writable)
        throw new Error("Desktop did not inherit the remote debugging pipe descriptors.");

    return { child, transport: new PipeTransport(readable as Readable, writable as Writable) };
}

export async function connectDebugTransport(address: string, port: number): Promise<CdpTransport>
{
    const url = new URL(address);
    if (url.protocol !== "ws:" || url.hostname !== "127.0.0.1" || url.port !== String(port)
        || !url.pathname.startsWith("/devtools/browser/") || url.username || url.password || url.search || url.hash)
        throw new Error("Desktop returned a non-loopback browser debug endpoint.");

    const socket = new WebSocket(address);
    const messages = new Set<(message: unknown) => void>();
    const closed = new Set<() => void>();
    let stopped = false;
    function close(): void
    {
        if (stopped)
            return;

        stopped = true;
        for (const listener of closed)
            listener();

        closed.clear();
        messages.clear();
        socket.close();
    }

    socket.addEventListener("message", (event) =>
    {
        if (typeof event.data !== "string" || Buffer.byteLength(event.data) > MAX_PIPE_MESSAGE_BYTES)
            return close();

        try
        {
            const message: unknown = JSON.parse(event.data);
            for (const listener of messages)
                listener(message);
        }
        catch
        {
            close();
        }
    });
    socket.addEventListener("close", close);
    socket.addEventListener("error", close);
    await new Promise<void>((resolve_, reject) =>
    {
        const timer = setTimeout(() =>
        {
            close();
            reject(new Error("Timed out opening Desktop's debug WebSocket."));
        }, 5000);
        socket.addEventListener("open", () =>
        {
            clearTimeout(timer);
            resolve_();
        }, { once: true });
        socket.addEventListener("error", () =>
        {
            clearTimeout(timer);
            reject(new Error("Cannot open Desktop's debug WebSocket."));
        }, { once: true });
    });
    return {
        send(message): void
        {
            if (stopped || socket.readyState !== WebSocket.OPEN)
                throw new Error("The Desktop debug connection is closed.");

            socket.send(JSON.stringify(message));
        },
        onMessage(listener): () => void
        {
            messages.add(listener);
            return () => messages.delete(listener);
        },
        onClose(listener): () => void
        {
            if (stopped)
                listener();
            else
                closed.add(listener);

            return () => closed.delete(listener);
        },
        close,
    };
}

export function openInDesktop(command: string, args: string[]): void
{
    const child = spawn(command, args, {
        detached: true,
        stdio: "ignore",
        env: cleanEnvironment(),
    });
    child.on("error", () =>
    {
    });
    child.unref();
}

function cleanEnvironment(): NodeJS.ProcessEnv
{
    const ret: NodeJS.ProcessEnv = {};
    for (const [name, value] of Object.entries(process.env))
        if (value !== undefined && !ENVIRONMENT_PREFIXES.some((prefix) => name.startsWith(prefix)))
            ret[name] = value;
    return ret;
}

function searchPath(command: string): string | undefined
{
    for (const directory of (process.env.PATH ?? "").split(delimiter))
    {
        if (!directory)
            continue;
        const candidate = join(directory, command);
        if (isExecutable(candidate))
            return candidate;
    }
    return undefined;
}

function isShellScript(path: string): boolean
{
    const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try
    {
        const head = Buffer.alloc(2);
        return readSync(descriptor, head, 0, 2, 0) === 2 && head.toString("utf8") === "#!";
    }
    finally
    {
        closeSync(descriptor);
    }
}

function isExecutable(path: string): boolean
{
    try
    {
        const attributes = statSync(path);
        return attributes.isFile() && (attributes.mode & 0o111) !== 0;
    }
    catch
    {
        return false;
    }
}
