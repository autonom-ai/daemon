/**
 * Autonom Command Center extension entrypoint.
 *
 * Runtime-only and opt-in: activation registers commands and does nothing else.
 * It never patches Desktop files, rewrites checksums, changes CSP, or writes to
 * Desktop's profile data directory. All work happens on an explicit command
 * against a trusted workspace, and every command returns a bounded status
 * object so it can be validated from an integration test.
 * See docs/COMMAND_CENTER_VALIDATION.md for the acceptance procedure.
 */
import { RuntimeCenter } from "./host/cdp";
import { CenterContent, loadCenter } from "./host/center";
import { autonomPageHtml } from "./commandCenter/content";
import { DaemonClient } from "./host/client";
import { configurationState, readSettings, saveDaemon, savePolicy, validateSettings } from "./host/config";

import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import * as vscode from "vscode";

class CommandError extends Error
{
}

let deactivateCenter: (() => Promise<void>) | undefined;

function sanitizedError(error: unknown): string
{
    if (error instanceof CommandError)
        return error.message;

    if (error instanceof Error
        && /9882|ECONNREFUSED|CDP|debugger|WebSocket|connect|timeout|closed|session/i.test(error.message))
        return "Runtime connection unavailable. Start Devin Desktop with loopback remote debugging on port 9882, "
            + "then run Autonom Command Center: Attach again.";

    return "Command failed. Verify the Command Center configuration and runtime build, then try Attach again.";
}

/**
 * Whitelists safe, bounded status fields for logging.
 *
 * Only known boolean/number fields and validated short strings are emitted, so
 * no renderer internals, paths, or credentials can leak into the output channel.
 */
function sanitizedStatus(status: unknown): string
{
    const ret: Record<string, unknown> = {};
    if (typeof status !== "object" || status === null)
        return JSON.stringify(ret);

    const record = status as Record<string, unknown>;
    for (const key of [
        "attached",
        "connected",
        "mode",
        "enabled",
        "patchOnlyIntegrityNoticeSuppressed",
        "port",
        "activeTab",
        "revision",
        "status",
        "state",
    ])
    {
        const value = record[key];
        if (typeof value === "boolean" || typeof value === "number" && Number.isFinite(value))
            ret[key] = value;
        else if ((key === "mode" && (value === "autonom" || value === "devin-cloud"))
            || (key === "activeTab" || key === "revision")
            && typeof value === "string" && /^[a-z0-9-]{1,64}$/i.test(value))
            ret[key] = value;
        else if ((key === "status" || key === "state") && typeof value === "string"
            && /^(attached|detached|connected|disconnected|enabled|disabled|unavailable|ready|idle)$/.test(value))
            ret[key] = value;
    }

    return JSON.stringify(ret);
}

export function activate(context: vscode.ExtensionContext): void
{
    const output = vscode.window.createOutputChannel("Autonom Command Center");
    const identity = randomUUID();
    let runtime: RuntimeCenter | undefined;
    let selectedPath: string | undefined;
    let lastContent: CenterContent | undefined;
    let pending: Promise<void> = Promise.resolve();
    let stopping = false;
    let detachPending: Promise<void> | undefined;
    let daemonClient: DaemonClient | undefined;

    function getDaemonClient(): DaemonClient
    {
        if (!daemonClient)
        {
            const settings = readSettings(vscode.workspace.getConfiguration("autonom"), context.extensionPath);
            daemonClient = new DaemonClient(settings);
        }
        return daemonClient;
    }

    function log(message: string): void
    {
        if (!stopping)
            output.appendLine(`[${new Date().toISOString()}] ${message}`);
    }

    function requireTrustedWorkspace(): void
    {
        if (!vscode.workspace.isTrusted)
            throw new CommandError("Trust this workspace before using the Autonom Command Center configuration.");
    }

    function configPath(argument?: unknown): string
    {
        if (argument !== undefined && (typeof argument !== "string" || !argument.trim()))
            throw new CommandError("Pass a nonempty configuration file path to Attach or Reload.");

        const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
        if (typeof argument === "string")
        {
            if (isAbsolute(argument))
                return resolve(argument);
            if (!folder)
                throw new CommandError("Open a workspace folder or pass an absolute configuration path to Attach.");

            return resolve(folder, argument);
        }

        if (selectedPath)
            return selectedPath;
        if (!folder)
            throw new CommandError("Open a workspace folder or pass an absolute configuration path to Attach.");

        return join(folder, ".devin", "commandCenter.json");
    }

    async function getRuntime(): Promise<RuntimeCenter>
    {
        if (!runtime)
        {
            let runtimeCode: string;
            try
            {
                runtimeCode = await readFile(context.asAbsolutePath("dist/commandCenter/native.js"), "utf8");
            }
            catch
            {
                throw new CommandError("The native runtime build is missing or unreadable. Rebuild or reinstall "
                    + "Autonom Command Center before attaching.");
            }

            runtime = new RuntimeCenter(runtimeCode, identity, vscode.env.appRoot);
        }

        return runtime;
    }

    /**
     * Validates a configuration and applies it to the running Desktop.
     *
     * Loads and fully validates the config first, so an invalid file changes
     * nothing. On the first attach it opens the native Agent view only when the
     * sidebar is not already mounted, then binds to this activation's renderer.
     */
    async function attach(argument?: unknown): Promise<unknown>
    {
        requireTrustedWorkspace();
        const path = configPath(argument);
        let content: CenterContent;
        try
        {
            content = await loadCenter(path);
        }
        catch (error)
        {
            const missing = typeof error === "object" && error !== null
                && "code" in error && error.code === "ENOENT";
            throw new CommandError(missing
                ? "The configuration or a referenced tab file is missing. Create .devin/commandCenter.json "
                    + "in the first workspace folder, or pass an existing configuration path to Attach or Reload."
                : "The configuration or referenced tab content is invalid, unreadable, or not private. "
                    + "Fix the configured file before running Attach or Reload; no changes were applied.");
        }

        let uiJs: string | undefined;
        let uiCss: string | undefined;
        for (const [, tab] of Object.entries(content.tabs))
        {
            if (tab.autonom)
            {
                if (uiJs === undefined)
                {
                    try
                    {
                        uiJs = await readFile(context.asAbsolutePath("dist/commandCenter/ui.js"), "utf8");
                    }
                    catch
                    {
                        uiJs = "";
                    }
                }
                if (uiCss === undefined)
                {
                    try
                    {
                        uiCss = await readFile(context.asAbsolutePath("dist/commandCenter/ui.css"), "utf8");
                    }
                    catch
                    {
                        uiCss = "";
                    }
                }
                tab.html = autonomPageHtml(tab, uiJs, uiCss);
            }
        }

        const center = await getRuntime();
        if (!(await center.status()).connected)
            await vscode.commands.executeCommand("workbench.action.commandCenter.goToAllSessions");
        const ret = await center.attach(content);
        selectedPath = path;
        lastContent = content;
        log(`Native status: ${sanitizedStatus(ret)}`);
        return ret;
    }

    /**
     * Pushes the rebuilt native runtime into the renderer without restarting.
     *
     * Re-reads the on-disk runtime bundle and hot-swaps it for the already
     * attached activation, reusing the current configuration. Intended for
     * rapid iteration; a release still requires validating the packaged VSIX.
     */
    async function hotReloadNative(): Promise<unknown>
    {
        requireTrustedWorkspace();
        if (!lastContent)
            throw new CommandError("Attach with a valid configuration before hot-reloading the native runtime.");
        let runtimeCode: string;
        try
        {
            runtimeCode = await readFile(context.asAbsolutePath("dist/commandCenter/native.js"), "utf8");
        }
        catch
        {
            throw new CommandError("The rebuilt native runtime bundle is missing or unreadable.");
        }

        let uiJs: string | undefined;
        let uiCss: string | undefined;
        for (const [, tab] of Object.entries(lastContent.tabs))
        {
            if (tab.autonom)
            {
                if (uiJs === undefined)
                {
                    try
                    {
                        uiJs = await readFile(context.asAbsolutePath("dist/commandCenter/ui.js"), "utf8");
                    }
                    catch
                    {
                        uiJs = "";
                    }
                }
                if (uiCss === undefined)
                {
                    try
                    {
                        uiCss = await readFile(context.asAbsolutePath("dist/commandCenter/ui.css"), "utf8");
                    }
                    catch
                    {
                        uiCss = "";
                    }
                }
                tab.html = autonomPageHtml(tab, uiJs, uiCss);
            }
        }

        const ret = await (await getRuntime()).reloadRuntime(runtimeCode, lastContent);
        log(`Native runtime hot-reloaded: ${sanitizedStatus(ret)}`);
        return ret;
    }

    async function disable(): Promise<unknown>
    {
        const center = await getRuntime();
        await center.detach();
        const ret = await center.status();
        log(`Native status: ${sanitizedStatus(ret)}`);
        return ret;
    }

    async function status(): Promise<unknown>
    {
        const ret = await (await getRuntime()).status();
        log(`Native status: ${sanitizedStatus(ret)}`);
        if (!stopping)
            output.show(true);

        return ret;
    }

    async function openTab(argument?: unknown): Promise<unknown>
    {
        requireTrustedWorkspace();
        if (!lastContent)
            throw new CommandError("Run Attach with a valid configuration before opening a Command Center tab.");
        if (argument !== undefined && typeof argument !== "string")
            throw new CommandError("Pass a configured tab ID to Open Tab.");

        let tabId = argument as string | undefined;
        if (tabId === undefined)
        {
            const tabs = Object.entries(lastContent.tabs).map(([id, page]) =>
            {
                return { label: page.title, description: id, tabId: id };
            });
            const selected = await vscode.window.showQuickPick(tabs, { placeHolder: "Open a Command Center tab" });
            if (!selected)
                return undefined;

            tabId = selected.tabId;
        }

        if (!Object.hasOwn(lastContent.tabs, tabId))
            throw new CommandError("The requested tab is not in the last successfully loaded configuration.");

        const ret = await (await getRuntime()).open(tabId);
        log(`Native status: ${sanitizedStatus(ret)}`);
        return ret;
    }

    async function editConfig(): Promise<vscode.TextEditor>
    {
        requireTrustedWorkspace();
        const path = configPath();
        try
        {
            return await vscode.window.showTextDocument(await vscode.workspace.openTextDocument(vscode.Uri.file(path)));
        }
        catch
        {
            throw new CommandError("The configured file cannot be opened. Create .devin/commandCenter.json "
                + "in the first workspace folder, or Attach with an existing configuration path first.");
        }
    }

    async function setMode(argument?: unknown): Promise<unknown>
    {
        requireTrustedWorkspace();
        const mode = argument as "autonom" | "devin-cloud";
        if (mode !== "autonom" && mode !== "devin-cloud")
            throw new CommandError("Mode must be autonom or devin-cloud.");
        const center = await getRuntime();
        const ret = await center.setMode(mode);
        log(`Native status: ${sanitizedStatus(ret)}`);
        return ret;
    }

    async function daemonRequest(argument?: unknown): Promise<unknown>
    {
        if (!argument || typeof argument !== "object")
            throw new Error("Invalid request payload.");
        const raw = argument as Record<string, unknown>;
        const message = (raw.params && typeof raw.params === "object" ? { ...raw, ...(raw.params as object) } : raw) as Record<string, unknown>;
        const action = String(raw.action || message.action || "");
        const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
        const client = getDaemonClient();

        switch (action)
        {
            case "getState":
                return await client.getState(folder);

            case "getModels":
                return await client.getModels();

            case "getMessages": {
                const source = message.source as "room" | "dm" | "pings";
                const target = String(message.target || "");
                return await client.getMessages(source, target);
            }

            case "postMessage": {
                const room = String(message.room || message.target || "");
                const text = String(message.text || "");
                const ping = Array.isArray(message.ping)
                    ? message.ping.map(String)
                    : (Array.isArray(message.pings) ? message.pings.map(String) : undefined);
                return await client.postMessage(room, text, ping);
            }

            case "getEvents": {
                const profile = String(message.profile || "");
                return await client.getEvents(profile);
            }

            case "getTranscript": {
                const id = String(message.id || "");
                return await client.getTranscript(id);
            }

            case "createProfile": {
                const name = String(message.name || "");
                return await client.createProfile(name);
            }

            case "removeProfile": {
                const name = String(message.name || "");
                return await client.removeProfile(name);
            }

            case "startSession": {
                const prompt = String(message.prompt || "");
                const model = String(message.model || "swe-2-medium");
                const mode = String(message.mode || "bypass");
                const directory = String(message.directory || folder || "");
                const profile = message.profile ? String(message.profile) : undefined;
                return await client.startSession({
                    prompt,
                    model,
                    mode,
                    directory,
                    ...(profile ? { profile } : {}),
                });
            }

            case "resumeSession": {
                const id = String(message.id || "");
                const prompt = String(message.prompt || "");
                return await client.resumeSession(id, prompt);
            }

            case "stopExecution": {
                const id = String(message.id || "");
                return await client.stopExecution(id);
            }

            case "removeSession": {
                const id = String(message.id || "");
                return await client.removeSession(id);
            }

            case "registerSession":
            case "manageSession": {
                const id = String(message.id || "");
                if (!id)
                    throw new Error("Session ID is required.");
                return await client.manageSession(id);
            }

            case "getExecution": {
                const id = String(message.id || "");
                return await client.getExecution(id);
            }

            case "getPolicy": {
                const settings = readSettings(vscode.workspace.getConfiguration("autonom"), context.extensionPath);
                return await configurationState(folder || "", settings.configFile);
            }

            case "getSettings": {
                return readSettings(vscode.workspace.getConfiguration("autonom"), context.extensionPath);
            }

            case "saveSettings": {
                const validated = validateSettings(message.settings);
                const config = vscode.workspace.getConfiguration("autonom");
                await config.update("port", validated.port, vscode.ConfigurationTarget.Global);
                await config.update("defaultModel", validated.defaultModel, vscode.ConfigurationTarget.Global);
                await config.update("permissionMode", validated.permissionMode, vscode.ConfigurationTarget.Global);
                await config.update("pollIntervalMs", validated.pollIntervalMs, vscode.ConfigurationTarget.Global);
                await config.update("notifyPings", validated.notifyPings, vscode.ConfigurationTarget.Global);
                if (validated.rootDirectory)
                    await config.update("rootDirectory", validated.rootDirectory, vscode.ConfigurationTarget.Global);
                if (validated.configFile)
                    await config.update("configFile", validated.configFile, vscode.ConfigurationTarget.Global);
                client.configure(validated);
                return { ok: true };
            }

            case "savePolicy": {
                if (!folder)
                    throw new Error("No workspace folder open.");
                const content = String(message.content || "");
                const version = String(message.version || "");
                await savePolicy(folder, content, version);
                return { ok: true };
            }

            case "saveDaemon": {
                const settings = readSettings(vscode.workspace.getConfiguration("autonom"), context.extensionPath);
                const values = message.values as Record<string, unknown>;
                await saveDaemon(settings.configFile, values);
                return { ok: true };
            }

            case "editConfig": {
                await vscode.commands.executeCommand("autonomCenter.editConfig");
                return { ok: true };
            }

            case "setMode": {
                const nextMode = message.mode as "autonom" | "devin-cloud";
                const center = await getRuntime();
                return await center.setMode(nextMode);
            }

            default:
                throw new Error(`Unknown daemon action: ${action}`);
        }
    }

    /**
     * Registers a command that serializes with the others and never rejects.
     *
     * Failures are logged with a sanitized message and returned as
     * `{ ok: false, error }`, so an integration test can assert the result and
     * the extension host never sees an unhandled rejection.
     */
    function register(command: string, action: (argument?: unknown) => Promise<unknown>): vscode.Disposable
    {
        return vscode.commands.registerCommand(command, (argument?: unknown) =>
        {
            const ret = pending.then(async () =>
            {
                if (stopping)
                    throw new CommandError("Autonom Command Center is shutting down.");

                return action(argument);
            }).catch((error: unknown) =>
            {
                const detail = sanitizedError(error);
                log(`${command}: ${detail}`);
                if (!stopping)
                {
                    void vscode.window.showErrorMessage(`Autonom Command Center: ${detail}`).then(undefined, () =>
                    {
                    });
                }

                return { ok: false, error: detail };
            });
            pending = ret.then(() =>
            {
            });
            return ret;
        });
    }

    function detach(): Promise<void>
    {
        stopping = true;
        if (!detachPending)
        {
            detachPending = pending.then(async () =>
            {
                await runtime?.detach();
            }).catch(() =>
            {
            });
        }

        return detachPending;
    }

    deactivateCenter = detach;
    context.subscriptions.push(
        output,
        register("autonomCenter.attach", attach),
        register("autonomCenter.reload", attach),
        register("autonomCenter.hotReload", hotReloadNative),
        register("autonomCenter.disable", disable),
        register("autonomCenter.status", status),
        register("autonomCenter.openTab", openTab),
        register("autonomCenter.editConfig", editConfig),
        register("autonomCenter.setMode", setMode),
        vscode.commands.registerCommand("autonomCenter.daemonRequest", daemonRequest),
        vscode.commands.registerCommand("autonomCenter.bridgeIdentity", () =>
        {
            return identity;
        }),
        {
            dispose: () =>
            {
                void detach();
            },
        },
    );

    // Auto-attach on startup when a workspace folder is open.
    if (vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders.length > 0)
    {
        void Promise.resolve().then(async () =>
        {
            try
            {
                await attach();
            }
            catch (error: unknown)
            {
                log(`Auto-attach skipped or failed: ${sanitizedError(error)}`);
            }
        });
    }
}

export async function deactivate(): Promise<void>
{
    await deactivateCenter?.();
    deactivateCenter = undefined;
}
