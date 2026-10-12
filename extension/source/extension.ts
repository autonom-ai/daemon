import { Controller } from "./host/controller";
import { configureKey, expand, readSettings, saveDaemon, savePolicy, validateSettings } from "./host/config";
import { installWorkspace } from "./host/setup";
import { PatchManager } from "./host/patch";
import { webviewHtml } from "./host/webview";
import { record, text } from "./protocol";
import type { HostMessage, Settings } from "./protocol";

import { access } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import * as vscode from "vscode";

export async function activate(context: vscode.ExtensionContext): Promise<void>
{
    let settings = readSettings(vscode.workspace.getConfiguration("autonom"), context.extensionUri.fsPath);
    let panel: vscode.WebviewPanel | undefined;
    let sidebar: vscode.WebviewView | undefined;
    let disposed = false;
    let notifiedCount = 0;
    let notificationInitialized = false;
    let previousSettings: Settings = settings;
    const webviews = new Set<vscode.Webview>();
    const controller = new Controller(settings, {
        workspace: () => workspace(),
        trusted: () => vscode.workspace.isTrusted,
        send: (message) => send(message),
        confirm: async (message, detail) => await vscode.window.showWarningMessage(
            message, { modal: true, detail }, "Confirm") === "Confirm",
        localAction: (type, message) => localAction(type, message),
    });
    const status = vscode.window.createStatusBarItem("autonom.connection", vscode.StatusBarAlignment.Left, 10);
    status.name = "Autonom";
    status.command = "autonom.open";
    status.text = "Autonom";
    status.tooltip = "Open the Autonom workspace";
    status.show();

    function workspace(): string
    {
        return vscode.workspace.workspaceFolders?.[0]?.uri.fsPath ?? "";
    }

    function send(message: HostMessage): void
    {
        for (const webview of webviews)
            void webview.postMessage(message);
        if (message.type !== "state")
            return;
        const state = message.state;
        const active = state.daemon.runs.filter((run) => run.status === "running" || run.status === "stopping").length;
        status.text = `Autonom${active ? ` · ${active}` : ""}`;
        status.tooltip = state.connected ? `${active} active run${active === 1 ? "" : "s"}. Open Autonom.` : state.error;
        if (sidebar !== undefined)
            sidebar.badge = state.daemon.humanEvents ? { value: state.daemon.humanEvents, tooltip: "Unread human events" }
                : undefined;
        if (notificationInitialized && settings.notifyPings && state.daemon.humanEvents > notifiedCount
            && !panel?.visible)
        {
            void vscode.window.showInformationMessage("You have a new Autonom ping.", "Open inbox").then((choice) =>
            {
                if (choice === "Open inbox")
                {
                    openPanel();
                    void controller.select({ kind: "pings", id: "human" });
                }
            });
        }
        notifiedCount = state.daemon.humanEvents;
        notificationInitialized = true;
    }

    function wire(webview: vscode.Webview, isSidebar: boolean): vscode.Disposable
    {
        webview.html = webviewHtml(webview, context.extensionUri, isSidebar);
        webviews.add(webview);
        const subscription = webview.onDidReceiveMessage((message: unknown) => void controller.handle(message));
        return { dispose: () => { webviews.delete(webview); subscription.dispose(); } };
    }

    function openPanel(): void
    {
        if (panel !== undefined)
        {
            panel.reveal(vscode.ViewColumn.Active);
            return;
        }
        const opened = vscode.window.createWebviewPanel("autonom.workspace", "Autonom", vscode.ViewColumn.Active,
            { retainContextWhenHidden: true, enableScripts: true });
        panel = opened;
        opened.iconPath = vscode.Uri.joinPath(context.extensionUri, "media", "autonom.svg");
        const subscription = wire(opened.webview, false);
        opened.onDidDispose(() => { subscription.dispose(); panel = undefined; });
        opened.onDidChangeViewState(() => { if (opened.visible) void controller.refresh(); });
        void controller.refresh();
    }

    async function localAction(type: string, message: Record<string, unknown>): Promise<void>
    {
        if (type === "open")
        {
            openPanel();
            return;
        }
        if (type === "settings")
        {
            await vscode.commands.executeCommand("autonom.control.focus");
            return;
        }
        if (type === "newSession")
        {
            openPanel();
            send({ type: "newSession" });
            return;
        }
        if (!vscode.workspace.isTrusted || !workspace())
            throw new Error("Open and trust a workspace before configuring Autonom.");
        switch (type)
        {
            case "setup":
            {
                const confirmed = await vscode.window.showInformationMessage("Set up this workspace for Autonom?", {
                    modal: true,
                    detail: "This installs Autonom hooks, adds its MCP server while preserving other servers and hooks, "
                        + "and creates a default policy only when none exists. Existing sessions must be restarted.",
                }, "Set up");
                if (confirmed !== "Set up")
                    return;
                await installWorkspace(workspace(), settings);
                void vscode.window.showInformationMessage("Autonom is ready. Start sessions from the Autonom tab.");
                break;
            }
            case "editPolicy":
                await openFile(join(workspace(), ".devin", "policy.yml"));
                break;
            case "editConfig":
                await openFile(controller.client.configurationPath || settings.configFile);
                break;
            case "saveSettings":
            {
                const proposed = validateSettings(message.settings);
                for (const [name, value] of Object.entries(proposed))
                {
                    if (value !== previousSettings[name as keyof Settings])
                        await vscode.workspace.getConfiguration("autonom").update(name, value,
                            vscode.ConfigurationTarget.Global);
                }
                previousSettings = proposed;
                break;
            }
            case "savePolicy":
                await savePolicy(workspace(), text(message.text), text(message.version));
                break;
            case "saveDaemon":
                await saveDaemon(controller.client.configurationPath || settings.configFile, record(message.values) ?? {});
                void vscode.window.showInformationMessage("Daemon settings saved. They take effect on its next start.");
                break;
            case "configureKey":
            {
                const key = await vscode.window.showInputBox({
                    title: "Autonom · OpenRouter key",
                    prompt: "Stored privately in your daemon YAML. Never sent to the webview.",
                    password: true,
                    ignoreFocusOut: true,
                });
                if (key !== undefined && key.trim())
                {
                    await configureKey(controller.client.configurationPath || settings.configFile, key.trim());
                    void vscode.window.showInformationMessage("OpenRouter key saved. Restart Autonom to apply it.");
                }
                break;
            }
            case "openLink":
            {
                const uri = vscode.Uri.parse(text(message.href));
                if (uri.scheme === "https" || uri.scheme === "http")
                    await vscode.env.openExternal(uri);
                else if (uri.scheme === "file")
                {
                    const path = relative(workspace(), uri.fsPath);
                    if (path.startsWith("..") || path.startsWith("/"))
                        throw new Error("File links must stay inside the active workspace.");
                    await openFile(uri.fsPath);
                }
                break;
            }
        }
        controller.invalidateConfiguration();
    }

    const provider: vscode.WebviewViewProvider = {
        resolveWebviewView(view): void
        {
            sidebar = view;
            const subscription = wire(view.webview, true);
            view.onDidDispose(() => { subscription.dispose(); sidebar = undefined; });
            view.onDidChangeVisibility(() => { if (view.visible) void controller.refresh(); });
        },
    };
    const watcher = vscode.workspace.createFileSystemWatcher("**/.devin/{policy.yml,hooks.v1.json,mcp_config.json}");
    const changed = (): void => { controller.invalidateConfiguration(); void controller.refresh(); };
    let timer: ReturnType<typeof setTimeout> | undefined;
    function poll(): void
    {
        if (disposed)
            return;
        if (panel?.visible || sidebar?.visible || controller.state.daemon.runs.some((run) => run.status === "running"))
            void controller.refresh();
        timer = setTimeout(poll, settings.pollIntervalMs);
    }
    context.subscriptions.push(
        status,
        watcher,
        watcher.onDidChange(changed),
        watcher.onDidCreate(changed),
        watcher.onDidDelete(changed),
        vscode.window.registerWebviewViewProvider("autonom.control", provider),
        vscode.commands.registerCommand("autonom.open", openPanel),
        vscode.commands.registerCommand("autonom.newSession", () => localAction("newSession", {})),
        vscode.commands.registerCommand("autonom.refresh", () => controller.refresh()),
        vscode.commands.registerCommand("autonom.setupWorkspace", () => localAction("setup", {})),
        vscode.commands.registerCommand("autonom.settings", () => vscode.commands.executeCommand("autonom.control.focus")),
        vscode.commands.registerCommand("autonom.policy", () => localAction("editPolicy", {})),
        vscode.commands.registerCommand("autonom.config", () => localAction("editConfig", {})),
        vscode.commands.registerCommand("autonom.patchCommandCenter", async () =>
        {
            try
            {
                await patchManager.applyPatch();
                const choice = await vscode.window.showInformationMessage(
                    "Autonom Command Center patch applied successfully. Reload window to take effect.",
                    "Reload Window"
                );
                if (choice === "Reload Window")
                    void vscode.commands.executeCommand("workbench.action.reloadWindow");
            }
            catch (err: any)
            {
                void vscode.window.showErrorMessage(`Failed to apply Command Center patch: ${err?.message || err}`);
            }
        }),
        vscode.commands.registerCommand("autonom.restoreCommandCenter", async () =>
        {
            const confirmed = await vscode.window.showWarningMessage(
                "Restore original Devin Desktop Command Center?",
                { modal: true, detail: "This restores pristine vendor files from backups." },
                "Restore"
            );
            if (confirmed === "Restore")
            {
                try
                {
                    await patchManager.restore();
                    const choice = await vscode.window.showInformationMessage(
                        "Command Center restored to original vendor version. Reload window to take effect.",
                        "Reload Window"
                    );
                    if (choice === "Reload Window")
                        void vscode.commands.executeCommand("workbench.action.reloadWindow");
                }
                catch (err: any)
                {
                    void vscode.window.showErrorMessage(`Failed to restore Command Center: ${err?.message || err}`);
                }
            }
        }),
        vscode.commands.registerCommand("autonom.verifyCommandCenter", async () =>
        {
            const status = await patchManager.checkStatus();
            if (!status.available)
            {
                void vscode.window.showInformationMessage("Devin Desktop Command Center was not detected in this environment.");
                return;
            }
            const info = [
                `Patched: ${status.patched ? "YES" : "NO"}`,
                `Writable: ${status.writable ? "YES" : "NO"}`,
                `Backup Present: ${status.hasBackup ? "YES" : "NO"}`,
                `Sessions Dir: ${status.sessionsDir}`,
            ].join("\n");
            void vscode.window.showInformationMessage("Autonom Command Center Status", { modal: true, detail: info });
        }),
        vscode.workspace.onDidChangeConfiguration(async (event) =>
        {
            if (!event.affectsConfiguration("autonom"))
                return;
            settings = readSettings(vscode.workspace.getConfiguration("autonom"), context.extensionUri.fsPath);
            await discoverRoot();
            controller.configure(settings);
            void controller.refresh();
        }),
        vscode.workspace.onDidGrantWorkspaceTrust(changed),
        { dispose: () => { disposed = true; if (timer !== undefined) clearTimeout(timer); panel?.dispose(); } },
    );
    const patchManager = new PatchManager(context);
    void patchManager.ensurePatched().then((result) =>
    {
        if (result.applied)
            console.log("[Autonom] Command Center surgical patch applied.");
    }).catch((err) =>
    {
        console.warn("[Autonom] Command Center patch check:", err);
    });
    await discoverRoot();
    timer = setTimeout(poll, settings.pollIntervalMs);

    async function discoverRoot(): Promise<void>
    {
        const configured = text(vscode.workspace.getConfiguration("autonom").get<string>("rootDirectory"));
        if (configured)
            return;
        const envRoot = text(process.env.AUTONOM_ROOT);
        const candidates: string[] = [];
        if (envRoot)
            candidates.push(expand(envRoot));
        candidates.push(
            resolve(context.extensionUri.fsPath, ".."),
            join(homedir(), "Repos", "autonom"),
            join(homedir(), "projects", "autonom"),
            join(homedir(), "autonom"),
        );
        for (const candidate of candidates)
        {
            if (await access(join(candidate, "source", "coord", "server.py")).then(() => true, () => false))
            {
                settings = { ...settings, rootDirectory: candidate };
                previousSettings = settings;
                controller.configure(settings);
                return;
            }
        }
        settings = { ...settings, rootDirectory: dirname(context.extensionUri.fsPath) };
        previousSettings = settings;
        controller.configure(settings);
    }
}

async function openFile(path: string): Promise<void>
{
    const document = await vscode.workspace.openTextDocument(vscode.Uri.file(path));
    await vscode.window.showTextDocument(document, { preview: false });
}
