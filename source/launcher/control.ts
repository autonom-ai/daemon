import type { CdpClient, CdpSession } from "./cdp";
import { object, text } from "./config";

import { chmod, lstat, mkdir, rm, writeFile } from "node:fs/promises";
import { createServer, createConnection } from "node:net";
import type { Socket } from "node:net";
import { dirname, join } from "node:path";

const MAX_REQUEST_BYTES = 1024 * 1024;
const MAX_SCREENSHOT_BYTES = 32 * 1024 * 1024;

export type ControlContext = {
    cdp: CdpClient;
    workbenchUrl: string;
    status: () => Promise<unknown>;
    hot: () => Promise<unknown>;
    detach: () => Promise<unknown>;
};

export function defaultSocketPath(): string
{
    const directory = process.env.XDG_RUNTIME_DIR || join(process.env.HOME || "/tmp", ".cache");
    return process.env.AUTONOM_LAUNCHER_SOCKET || join(directory, "autonom", "launcher.sock");
}

export async function startControlSocket(path: string, context: ControlContext): Promise<{ close: () => Promise<void> }>
{
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    if (await isLauncherRunning(path))
        throw new Error(`Another Autonom launcher is already listening on ${path}.`);

    const previous = await lstat(path).catch((error) =>
    {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT")
            throw error;

        return undefined;
    });
    if (previous && !previous.isSocket())
        throw new Error("The control socket path is occupied by a non-socket file.");

    await rm(path, { force: true });
    const server = createServer((socket) =>
    {
        handle(socket, context);
    });
    await new Promise<void>((resolve_, reject) =>
    {
        server.once("error", reject);
        server.listen(path, () =>
        {
            resolve_();
        });
    });
    await chmod(path, 0o600);
    return {
        close: () => new Promise((resolve_) =>
        {
            server.close(() =>
            {
                void rm(path, { force: true }).then(() => resolve_(), () => resolve_());
            });
        }),
    };
}

function handle(socket: Socket, context: ControlContext): void
{
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("error", () =>
    {
    });
    socket.on("data", (chunk: string) =>
    {
        buffer += chunk;
        if (buffer.length > MAX_REQUEST_BYTES)
        {
            socket.destroy();
            return;
        }
        let end = buffer.indexOf("\n");
        while (end >= 0)
        {
            const line = buffer.slice(0, end);
            buffer = buffer.slice(end + 1);
            end = buffer.indexOf("\n");
            if (!line.trim())
                continue;
            void dispatch(socket, context, line);
        }
    });
}

async function dispatch(socket: Socket, context: ControlContext, line: string): Promise<void>
{
    try
    {
        const message = object(JSON.parse(line));
        if (message === undefined)
            throw new Error("The control request must be a JSON object.");
        const result = await action(context, message);
        reply(socket, { result: result ?? null });
    }
    catch (error)
    {
        reply(socket, { error: error instanceof Error ? error.message : "The control request failed." });
    }
}

async function action(context: ControlContext, message: Record<string, unknown>): Promise<unknown>
{
    switch (text(message.action))
    {
        case "status":
            return await context.status();

        case "targets":
            return await context.cdp.targets();

        case "eval": {
            const session = await selectSession(context, message.target);
            try
            {
                return await session.evaluate(text(message.expression));
            }
            finally
            {
                await session.detach();
            }
        }

        case "screenshot": {
            const path = text(message.path);
            if (!path)
                throw new Error("A screenshot path is required.");
            const session = await selectSession(context, message.target);
            try
            {
                const ret = await session.request("Page.captureScreenshot", { format: "png" });
                const data = text(ret.data);
                if (!data)
                    throw new Error("The renderer did not return a screenshot.");

                const png = Buffer.from(data, "base64");
                if (png.length > MAX_SCREENSHOT_BYTES)
                    throw new Error("The screenshot exceeds the size limit.");

                await writeFile(path, png, { flag: "wx", mode: 0o600 });
                return { path, bytes: png.length };
            }
            finally
            {
                await session.detach();
            }
        }

        case "hot":
            return await context.hot();

        case "detach":
            return await context.detach();

        default:
            throw new Error(`Unknown control action: ${text(message.action)}`);
    }
}

async function selectSession(context: ControlContext, selector: unknown): Promise<CdpSession>
{
    const match = text(selector);
    const targets = (await context.cdp.targets())
        .filter((target) => target.type === "page" && target.url.split(/[?#]/)[0] === context.workbenchUrl
            || ["page", "iframe"].includes(target.type) && target.id === match);
    const target = match
        ? targets.find((item) => item.id.includes(match) || item.url.includes(match))
        : targets[0];
    if (!target)
        throw new Error("No matching Devin Desktop workbench target.");
    return await context.cdp.attach(target.id);
}

function reply(socket: Socket, message: unknown): void
{
    if (!socket.destroyed)
        socket.write(`${JSON.stringify(message)}\n`);
}

export function isLauncherRunning(path: string): Promise<boolean>
{
    return new Promise((resolve_) =>
    {
        const socket = createConnection(path);
        socket.on("connect", () =>
        {
            socket.destroy();
            resolve_(true);
        });
        socket.on("error", () =>
        {
            socket.destroy();
            resolve_(false);
        });
        socket.setTimeout(1000, () =>
        {
            socket.destroy();
            resolve_(false);
        });
    });
}
