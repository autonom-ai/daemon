import type { DaemonClient } from "./client";
import type { LauncherSettings } from "./config";
import { ensureDefaultConfig, readDaemonConfig, readDataDir, saveDaemon, saveSettings, validateSettings } from "./config";
import { object, text } from "./config";

import { randomBytes, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import { join } from "node:path";

const MAX_REQUEST_BYTES = 256 * 1024;
const CORS_HEADERS = {
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "content-type, x-autonom-bridge",
    "access-control-allow-methods": "POST",
};

export type BridgeContext = {
    workspace: string;
    repository: string;
    settingsPath: string;
    settings: LauncherSettings;
    client: DaemonClient;
    openPath: (path: string) => void;
    getAction: (id: string, revision: string) => Promise<unknown>;
    runScript: (id: string, revision: string, windowId: number) => Promise<unknown>;
    reloadUi: () => Promise<unknown>;
};

export type Bridge = {
    url: string;
    token: string;
    close: () => Promise<void>;
};

export async function startBridge(context: BridgeContext): Promise<Bridge>
{
    const token = randomBytes(32).toString("hex");
    const server = createServer((request, response) =>
    {
        void respond(context, token, request, response);
    });
    await new Promise<void>((resolve_, reject) =>
    {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", resolve_);
    });
    const address = server.address();
    if (address === null || typeof address === "string")
        throw new Error("The Command Center bridge did not bind a loopback port.");
    return {
        url: `http://127.0.0.1:${address.port}`,
        token,
        close: () => new Promise((resolve_) =>
        {
            server.close(() => resolve_());
        }),
    };
}

async function respond(
    context: BridgeContext,
    token: string,
    request: IncomingMessage,
    response: ServerResponse,
): Promise<void>
{
    try
    {
        if (request.method === "OPTIONS")
        {
            response.writeHead(204, CORS_HEADERS);
            response.end();
            return;
        }
        if (request.method !== "POST" || request.url !== "/request")
            return fail(response, 404, "Unknown bridge endpoint.");
        const provided = Buffer.from(text(request.headers["x-autonom-bridge"]));
        const expected = Buffer.from(token);
        if (provided.length !== expected.length || !timingSafeEqual(provided, expected))
            return fail(response, 403, "The Command Center bridge token is invalid.");
        const message = object(JSON.parse(await readBody(request)));
        if (message === undefined)
            return fail(response, 400, "The bridge request must be a JSON object.");
        const result = await dispatch(context, message);
        response.writeHead(200, { ...CORS_HEADERS, "content-type": "application/json" });
        response.end(JSON.stringify({ result: result ?? null }));
    }
    catch (error)
    {
        fail(response, 400, error instanceof Error ? error.message : "The bridge request failed.");
    }
}

async function dispatch(context: BridgeContext, message: Record<string, unknown>): Promise<unknown>
{
    switch (text(message.action))
    {
        case "getAction":
            return context.getAction(text(message.id), text(message.revision));

        case "runScript":
            if (!Number.isSafeInteger(message.windowId))
                throw new Error("A valid Desktop window id is required for JS actions.");

            return context.runScript(text(message.id), text(message.revision), message.windowId as number);

        case "reloadUi":
            return context.reloadUi();

        case "getState":
            return await context.client.getState(context.workspace);

        case "getSettings":
            return {
                port: context.settings.port,
                configFile: context.settings.configFile,
                commandCenterConfig: context.settings.commandCenterConfig,
                repository: context.repository,
                workspace: context.workspace,
                dataDir: await readDataDir(context.settings.configFile),
            };

        case "saveSettings": {
            const settings = { ...context.settings, ...validateSettings(message.settings) };
            await saveSettings(context.settingsPath, settings);
            Object.assign(context.settings, settings);
            context.client.configure({
                port: settings.port,
                configFile: settings.configFile,
                rootDirectory: context.repository,
            });
            return { ok: true };
        }

        case "getDaemon":
            return { workspace: context.workspace, daemon: await readDaemonConfig(context.settings.configFile) };

        case "saveDaemon":
            await saveDaemon(context.settings.configFile, message.values);
            return { ok: true };

        case "editConfig":
            await ensureDefaultConfig(context.settings.configFile);
            context.openPath(context.settings.configFile);
            return { ok: true };

        case "editPolicy":
            context.openPath(join(context.workspace, ".devin", "policy.yml"));
            return { ok: true };

        default:
            throw new Error(`Unknown bridge action: ${text(message.action)}`);
    }
}

async function readBody(request: IncomingMessage): Promise<string>
{
    const chunks: Buffer[] = [];
    let bytes = 0;
    for await (const chunk of request)
    {
        bytes += (chunk as Buffer).length;
        if (bytes > MAX_REQUEST_BYTES)
            throw new Error("The bridge request exceeds the size limit.");
        chunks.push(chunk as Buffer);
    }
    return Buffer.concat(chunks).toString("utf8");
}

function fail(response: ServerResponse, status: number, error: string): void
{
    response.writeHead(status, { ...CORS_HEADERS, "content-type": "application/json" });
    response.end(JSON.stringify({ error }));
}
