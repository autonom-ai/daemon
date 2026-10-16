import type { Bridge } from "../../bridge";
import { startBridge } from "../../bridge";
import type { DaemonClient } from "../../client";
import type { LauncherSettings } from "../../config";
import { readDaemonConfig, readSettings, saveDaemon } from "../../config";

import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

type Context = {
    bridge: Bridge;
    root: string;
    settings: LauncherSettings;
    opened: string[];
    configured: unknown[];
    settingsPath: string;
    close: () => Promise<void>;
};

async function context(): Promise<Context>
{
    const root = await mkdtemp(join(tmpdir(), "autonom-bridge-"));
    const settingsPath = join(root, "launcher.yml");
    const settings: LauncherSettings = {
        port: 8080,
        configFile: join(root, "config.yml"),
        commandCenterConfig: join(root, "ui.yml"),
    };
    await writeFile(settings.configFile, "dataDir: ~/.local/share/autonom\ndevinCommand: devin\n");
    const opened: string[] = [];
    const configured: unknown[] = [];
    const client = {
        async getState(directory?: string): Promise<unknown>
        {
            return { directory };
        },
        configure(next: unknown): void
        {
            configured.push(next);
        },
    } as unknown as DaemonClient;
    const bridge = await startBridge({
        workspace: root,
        repository: "/repository",
        settingsPath,
        settings,
        client,
        openPath: (path) =>
        {
            opened.push(path);
        },
        getAction: async (id, revision) => ({ type: "html", source: `<h1>${id}</h1>`, revision }),
        runScript: async (id, revision, windowId) => ({ id, revision, windowId }),
        reloadUi: async () => ({ reloaded: true }),
    });
    return {
        bridge,
        root,
        settings,
        opened,
        configured,
        settingsPath,
        close: async () =>
        {
            await bridge.close();
            await rm(root, { force: true, recursive: true });
        },
    };
}

async function request(bridge: Bridge, body: unknown, token = bridge.token): Promise<{ status: number; body: any }>
{
    const response = await fetch(`${bridge.url}/request`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-autonom-bridge": token },
        body: JSON.stringify(body),
    });
    return { status: response.status, body: await response.json() };
}

test("the bridge binds loopback and rejects unauthenticated requests", async () =>
{
    const environment = await context();
    try
    {
        assert.match(environment.bridge.url, /^http:\/\/127\.0\.0\.1:\d+$/);
        assert.equal((await request(environment.bridge, { action: "getSettings" }, "wrong")).status, 403);
        const missing = await fetch(`${environment.bridge.url}/request`, { method: "POST", body: "{}" });
        assert.equal(missing.status, 403);
        assert.equal((await fetch(`${environment.bridge.url}/other`)).status, 404);
    }
    finally
    {
        await environment.close();
    }
});

test("the bridge answers the renderer's CORS preflight without a token", async () =>
{
    const environment = await context();
    try
    {
        const preflight = await fetch(`${environment.bridge.url}/request`, {
            method: "OPTIONS",
            headers: {
                origin: "vscode-file://vscode-app",
                "access-control-request-method": "POST",
                "access-control-request-headers": "content-type, x-autonom-bridge",
            },
        });
        assert.equal(preflight.status, 204);
        assert.equal(preflight.headers.get("access-control-allow-origin"), "*");
        assert.equal(preflight.headers.get("access-control-allow-headers"), "content-type, x-autonom-bridge");
        const response = await request(environment.bridge, { action: "getSettings" });
        assert.equal(response.status, 200);
        assert.equal(response.body.result.port, 8080);
    }
    finally
    {
        await environment.close();
    }
});

test("the bridge serves daemon state and launcher paths", async () =>
{
    const environment = await context();
    try
    {
        const state = await request(environment.bridge, { action: "getState" });
        assert.equal(state.status, 200);
        assert.deepEqual(state.body.result, { directory: environment.root });
        const settings = await request(environment.bridge, { action: "getSettings" });
        assert.deepEqual(settings.body.result, {
            port: 8080,
            configFile: environment.settings.configFile,
            commandCenterConfig: environment.settings.commandCenterConfig,
            repository: "/repository",
            workspace: environment.root,
            dataDir: join(process.env.HOME ?? "", ".local/share/autonom"),
        });
        const daemon = await request(environment.bridge, { action: "getDaemon" });
        assert.deepEqual(daemon.body.result.daemon, { dataDir: "~/.local/share/autonom", devinCommand: "devin" });
    }
    finally
    {
        await environment.close();
    }
});

test("UI action requests stay authenticated and carry the renderer window and revision", async () =>
{
    const environment = await context();
    try
    {
        const source = await request(environment.bridge, { action: "getAction", id: "page", revision: "one" });
        assert.deepEqual(source.body.result, { type: "html", source: "<h1>page</h1>", revision: "one" });
        const script = await request(environment.bridge, { action: "runScript", id: "run", revision: "one", windowId: 2 });
        assert.deepEqual(script.body.result, { id: "run", revision: "one", windowId: 2 });
        assert.equal((await request(environment.bridge, { action: "runScript", id: "run", revision: "one" })).status, 400);
        assert.equal((await request(environment.bridge, { action: "runScript", windowId: "2" })).status, 400);
        assert.equal((await request(environment.bridge, { action: "runScript", windowId: 2 }, "wrong")).status, 403);
        assert.deepEqual((await request(environment.bridge, { action: "reloadUi" })).body.result, { reloaded: true });
    }
    finally
    {
        await environment.close();
    }
});

test("the bridge saves launcher settings, daemon settings, and opens configuration files", async () =>
{
    const environment = await context();
    try
    {
        const saved = await request(environment.bridge, { action: "saveSettings", settings: { port: 9090 } });
        assert.equal(saved.status, 200);
        assert.equal(environment.settings.port, 9090);
        assert.deepEqual(await readSettings(environment.settingsPath), {
            port: 9090,
            configFile: environment.settings.configFile,
            commandCenterConfig: environment.settings.commandCenterConfig,
        });
        assert.deepEqual(environment.configured, [{
            port: 9090,
            configFile: environment.settings.configFile,
            rootDirectory: "/repository",
        }]);
        const invalid = await request(environment.bridge, { action: "saveSettings", settings: { port: 0 } });
        assert.equal(invalid.status, 400);
        assert.match(invalid.body.error, /between 1 and 65535/);

        const daemon = await request(environment.bridge, { action: "saveDaemon", values: { compactOnResume: true } });
        assert.equal(daemon.status, 200);
        assert.equal((await readDaemonConfig(environment.settings.configFile)).compactOnResume, true);
        await saveDaemon(environment.settings.configFile, { compactOnResume: false });

        await request(environment.bridge, { action: "editConfig" });
        await request(environment.bridge, { action: "editPolicy" });
        assert.deepEqual(environment.opened, [
            environment.settings.configFile,
            join(environment.root, ".devin", "policy.yml"),
        ]);

        const unknown = await request(environment.bridge, { action: "nonsense" });
        assert.equal(unknown.status, 400);
        assert.match(unknown.body.error, /Unknown bridge action/);
    }
    finally
    {
        await environment.close();
    }
});
