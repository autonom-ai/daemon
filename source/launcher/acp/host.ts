import type { DaemonClient } from "../client";
import { object } from "../config";

import { chmod, lstat, mkdir, unlink } from "node:fs/promises";
import { createServer } from "node:net";
import type { Server, Socket } from "node:net";
import { dirname } from "node:path";

const MAX_FRAME_BYTES = 16 * 1024 * 1024;
const SESSION_ID = /^[A-Za-z0-9_.-]{1,128}$/;
const EXECUTION_ID = /^[A-Fa-f0-9-]{36}$/;

type AcpHookHost = {
    socketPath: string;
    close(): Promise<void>;
};

type IpcRequest = {
    id: string;
    action: "request";
    path: string;
    method?: string;
    body?: unknown;
};

export async function startAcpHost(client: DaemonClient, socketPath: string): Promise<AcpHookHost>
{
    const directory = dirname(socketPath);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const directoryStat = await lstat(directory);
    if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()
        || (process.getuid !== undefined && directoryStat.uid !== process.getuid())
        || (directoryStat.mode & 0o077) !== 0)
        throw new Error("Autonom ACP socket directory must be private and user-owned.");

    const sockets = new Set<Socket>();
    const activeExecutions = new Map<Socket, Set<string>>();
    const cleanups = new Set<Promise<void>>();
    const server: Server = createServer((socket) =>
    {
        sockets.add(socket);
        activeExecutions.set(socket, new Set());
        serve(socket);
        socket.on("close", () =>
        {
            sockets.delete(socket);
            const executions = activeExecutions.get(socket) ?? new Set<string>();
            activeExecutions.delete(socket);
            const cleanup = stopExecutions(client, executions).finally(() => cleanups.delete(cleanup));
            cleanups.add(cleanup);
        });
    });

    function send(socket: Socket, message: unknown): void
    {
        if (socket.destroyed)
            return;

        socket.write(`${JSON.stringify(message)}\n`);
    }

    function serve(socket: Socket): void
    {
        let buffer = Buffer.alloc(0);
        socket.on("data", (chunk: Buffer) =>
        {
            buffer = Buffer.concat([buffer, chunk]);
            if (buffer.length > MAX_FRAME_BYTES)
            {
                socket.destroy();
                return;
            }

            let end = buffer.indexOf(0x0a);
            while (end >= 0)
            {
                const frame = buffer.subarray(0, end);
                buffer = buffer.subarray(end + 1);
                end = buffer.indexOf(0x0a);
                if (!frame.length)
                    continue;
                if (frame.length > MAX_FRAME_BYTES)
                {
                    socket.destroy();
                    return;
                }

                void dispatch(socket, frame.toString("utf8"));
            }
        });
        socket.on("error", () => socket.destroy());
    }

    async function dispatch(socket: Socket, frame: string): Promise<void>
    {
        let request: IpcRequest | undefined;
        try
        {
            const value = object(JSON.parse(frame));
            if (!value || typeof value.id !== "string" || value.action !== "request"
                || typeof value.path !== "string")
                throw new Error("Invalid ACP hook request.");
            request = value as unknown as IpcRequest;
            validateRequest(request);
            const result = await client.request(request.path, request.method ?? "GET", request.body);
            trackExecution(socket, request, result, activeExecutions);
            send(socket, { id: request.id, result });
        }
        catch (error)
        {
            send(socket, {
                id: request?.id ?? "",
                error: error instanceof Error ? error.message : "Autonom ACP request failed.",
            });
        }
    }

    await new Promise<void>((resolve_, reject) =>
    {
        server.once("error", reject);
        server.listen(socketPath, resolve_);
    });
    await chmod(socketPath, 0o600);
    const socketStat = await lstat(socketPath);

    return {
        socketPath,
        async close(): Promise<void>
        {
            for (const socket of sockets)
                socket.destroy();
            await new Promise<void>((resolve_) => server.close(() => resolve_()));
            await Promise.allSettled(cleanups);
            const current = await lstat(socketPath).catch(() => undefined);
            if (current?.isSocket() && current.dev === socketStat.dev && current.ino === socketStat.ino)
                await unlink(socketPath).catch(() => undefined);
        },
    };
}

function validateRequest(request: IpcRequest): void
{
    const url = new URL(request.path, "http://autonom.invalid");
    if (url.origin !== "http://autonom.invalid" || !url.pathname.startsWith("/api/") || url.hash)
        throw new Error("Invalid Autonom ACP API path.");

    const method = request.method ?? "GET";
    const segments = url.pathname.split("/").slice(1);
    if (segments.length === 2 && segments[0] === "api" && segments[1] === "acp" && method === "POST")
        return;

    if (segments[0] === "api" && segments[1] === "acp" && EXECUTION_ID.test(segments[2] ?? ""))
    {
        if (segments.length === 3 && method === "POST")
            return;
        if (segments.length === 3 && method === "GET" && /^[0-9]{1,20}$/.test(url.searchParams.get("offset") ?? "0"))
            return;
        if (segments.length === 4 && segments[3] === "bind" && method === "POST")
            return;
    }

    if (segments[0] === "api" && segments[1] === "executions" && EXECUTION_ID.test(segments[2] ?? ""))
    {
        if (segments.length === 3 && method === "GET")
            return;
        if (segments.length === 4 && segments[3] === "stop" && method === "POST")
            return;
    }

    if (segments[0] === "api" && segments[1] === "client" && segments[2] === "transcript"
        && SESSION_ID.test(segments[3] ?? "") && segments.length === 4 && method === "GET")
        return;

    throw new Error("Autonom ACP request is not allowed through the launcher hook.");
}

function trackExecution(
    socket: Socket,
    request: IpcRequest,
    result: unknown,
    activeExecutions: Map<Socket, Set<string>>
): void
{
    const active = activeExecutions.get(socket);
    if (!active)
        return;

    const url = new URL(request.path, "http://autonom.invalid");
    if (url.pathname === "/api/acp" && request.method === "POST")
    {
        const execution = object(result)?.id;
        if (typeof execution === "string" && EXECUTION_ID.test(execution))
            active.add(execution);
        return;
    }

    const match = /^\/api\/executions\/([A-Fa-f0-9-]{36})$/.exec(url.pathname);
    const status = object(result)?.status;
    if (match && request.method === "GET" && status !== "running" && status !== "stopping")
        active.delete(match[1]!);
}

async function stopExecutions(client: DaemonClient, executions: Set<string>): Promise<void>
{
    for (const id of executions)
    {
        await client.request(`/api/executions/${id}/stop`, "POST", {}).catch(() => undefined);
        const deadline = Date.now() + 10000;
        while (Date.now() < deadline)
        {
            const record = await client.request<Record<string, unknown>>(`/api/executions/${id}`).catch(() => undefined);
            if (!record || record.status !== "running" && record.status !== "stopping")
                break;

            await new Promise((resolve_) => setTimeout(resolve_, 50));
        }
    }
}
