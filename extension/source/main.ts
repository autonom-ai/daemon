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
}

export async function deactivate(): Promise<void>
{
    await deactivateCenter?.();
    deactivateCenter = undefined;
}
