import type { ChildProcess } from "node:child_process";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, constants, openSync, readSync, statSync } from "node:fs";
import { open } from "node:fs/promises";
import { basename, delimiter, dirname, isAbsolute, join, resolve } from "node:path";
import type { Readable, Writable } from "node:stream";
import { pathToFileURL } from "node:url";

export const DESKTOP_VERSION = "1.126.0";
export const DESKTOP_COMMIT = "fcf7ba39e6150055fad817f8716385b4d320d46d";
export const WORKBENCH_HASH = "da45742ddd56f8d83e38c4c4a57802ffe4b6cc98645a787588eda346d455f22d";

const MAX_PIPE_MESSAGE_BYTES = 32 * 1024 * 1024;
const MAX_METADATA_BYTES = 1024 * 1024;
const MAX_BUNDLE_BYTES = 64 * 1024 * 1024;
const DISABLED_EXTENSIONS = ["cet.autonom", "cet.autonom-command-center"];

export class PipeTransport
{
    private buffer = Buffer.alloc(0);
    private readonly listeners = new Set<(message: unknown) => void>();
    private readonly closeListeners = new Set<() => void>();
    private closed = false;

    constructor(readable: Readable, private readonly writable: Writable)
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
    const resolved = command.includes("/") || isAbsolute(command) ? resolve(command) : searchPath(command);
    if (resolved === undefined || !isExecutable(resolved))
        throw new Error(`Cannot find the Devin Desktop command '${command}'. Pass it with --desktop.`);
    if (basename(dirname(resolved)) === "bin" && isShellScript(resolved))
    {
        const binary = join(dirname(dirname(resolved)), basename(resolved));
        if (!isExecutable(binary))
            throw new Error(`Cannot find the Devin Desktop binary beside ${resolved}. Pass it with --desktop.`);
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

export async function verifyDesktopBuild(appRoot: string): Promise<void>
{
    const product = await readMetadata(join(appRoot, "product.json"));
    const metadata = await readMetadata(join(appRoot, "package.json"));
    if (metadata.version !== DESKTOP_VERSION || product.commit !== DESKTOP_COMMIT)
        throw new Error(`Unsupported Devin Desktop build. The Command Center requires version ${DESKTOP_VERSION} and its pinned commit.`);
    const hash = createHash("sha256");
    const descriptor = await open(join(appRoot, "out/vs/workbench/workbench.desktop.main.js"),
        constants.O_RDONLY | constants.O_NOFOLLOW);
    try
    {
        const attributes = await descriptor.stat();
        if (!attributes.isFile() || attributes.size > MAX_BUNDLE_BYTES)
            throw new Error("The native Desktop host bundle is not a bounded regular file.");
        for await (const chunk of descriptor.createReadStream({ autoClose: false }))
            hash.update(chunk as Buffer);
    }
    finally
    {
        await descriptor.close();
    }
    if (hash.digest("hex") !== WORKBENCH_HASH)
        throw new Error("The native Desktop host bundle is not the verified pristine build. Restore it before launching.");
}

export function launchDesktop(options: { binary: string; workspace: string }): { child: ChildProcess; transport: PipeTransport }
{
    const args = ["--remote-debugging-pipe"];
    for (const extension of DISABLED_EXTENSIONS)
        args.push("--disable-extension", extension);
    args.push(options.workspace);
    const child = spawn(options.binary, args, {
        cwd: options.workspace,
        detached: false,
        stdio: ["ignore", "inherit", "inherit", "pipe", "pipe"],
        env: { ...process.env, VSCODE_CWD: options.workspace },
    });
    const readable = child.stdio[4];
    const writable = child.stdio[3];
    if (!readable || !writable)
        throw new Error("Desktop did not inherit the remote debugging pipe descriptors.");
    return { child, transport: new PipeTransport(readable as Readable, writable as Writable) };
}

export function openInDesktop(command: string, path: string): void
{
    const child = spawn(command, [path], { detached: true, stdio: "ignore" });
    child.on("error", () =>
    {
    });
    child.unref();
}

async function readMetadata(path: string): Promise<Record<string, unknown>>
{
    const descriptor = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try
    {
        const attributes = await descriptor.stat();
        if (!attributes.isFile() || attributes.size > MAX_METADATA_BYTES)
            throw new Error("The Desktop build metadata is not a bounded regular file.");
        const parsed: unknown = JSON.parse((await descriptor.readFile("utf8")));
        if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed))
            throw new Error("Invalid Desktop build metadata.");
        return parsed as Record<string, unknown>;
    }
    finally
    {
        await descriptor.close();
    }
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
