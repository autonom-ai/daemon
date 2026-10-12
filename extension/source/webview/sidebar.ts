import { bridge, field, toast } from "./bridge";
import { escape, icon, modeOptions } from "./dom";
import type { Settings, ViewState } from "../protocol";

export class Sidebar
{
    private root: HTMLElement;
    private state: ViewState | undefined;
    private signature = "";
    private dirty = false;

    constructor(root: HTMLElement)
    {
        this.root = root;
        root.addEventListener("input", () => { this.dirty = true; });
        root.addEventListener("click", (event) =>
        {
            const button = (event.target as Element).closest<HTMLButtonElement>("[data-action]");
            const action = button?.dataset.action;
            if (action === "open" || action === "newSession" || action === "setup" || action === "editPolicy"
                || action === "editConfig" || action === "configureKey")
                bridge.postMessage({ type: action });
            if (action === "refresh")
            {
                this.dirty = false;
                this.signature = "";
                bridge.postMessage({ type: "refresh" });
            }
        });
        root.addEventListener("submit", (event) =>
        {
            event.preventDefault();
            const form = event.target as HTMLFormElement;
            if (form.id === "connection-form")
            {
                const settings: Settings = {
                    rootDirectory: field(form, "rootDirectory"),
                    configFile: field(form, "configFile"),
                    port: Number(field(form, "port")),
                    defaultModel: field(form, "defaultModel"),
                    permissionMode: field(form, "permissionMode") as Settings["permissionMode"],
                    pollIntervalMs: Number(field(form, "pollIntervalMs")),
                    notifyPings: new FormData(form).has("notifyPings"),
                };
                bridge.postMessage({ type: "saveSettings", settings });
            }
            if (form.id === "policy-form")
                bridge.postMessage({ type: "savePolicy", text: field(form, "policy"),
                    version: this.state?.configuration?.policyVersion ?? "" });
            if (form.id === "daemon-form")
                bridge.postMessage({ type: "saveDaemon", values: {
                    devinCommand: field(form, "devinCommand"),
                    offlineStartAfter: field(form, "offlineStartAfter"),
                    offlineCompactAfter: field(form, "offlineCompactAfter"),
                    compactionThresholds: field(form, "compactionThresholds"),
                    executionTimeout: field(form, "executionTimeout"),
                    compactOnResume: new FormData(form).has("compactOnResume"),
                } });
        });
    }

    saved(action: string, ok: boolean): void
    {
        if (!["saveSettings", "savePolicy", "saveDaemon", "setup", "configureKey"].includes(action))
            return;
        if (ok)
        {
            this.dirty = false;
            this.signature = "";
            const messages: Record<string, string> = {
                saveSettings: "Settings saved.",
                savePolicy: "Saved. Workspace policy changes apply immediately.",
                saveDaemon: "Daemon settings saved. Changes take effect on next daemon start.",
                setup: "Workspace setup complete.",
                configureKey: "OpenRouter key configured.",
            };
            toast(messages[action] || "Saved.");
        }
    }

    render(state: ViewState): void
    {
        this.state = state;
        const signature = JSON.stringify([state.settings, state.configuration]);
        if (this.dirty || signature === this.signature)
        {
            this.updateConnection(state);
            return;
        }
        this.signature = signature;
        const settings = state.settings;
        const config = state.configuration;
        const daemon = config?.daemon ?? {};
        const value = (key: string, fallback: string): string => escape(daemon[key] ?? fallback);
        const existingCards = Array.from(this.root.querySelectorAll<HTMLDetailsElement>("details.control-card"));
        const hadCards = existingCards.length > 0;
        const openCards = new Set<string>();
        if (hadCards)
        {
            existingCards.forEach((card) =>
            {
                if (card.open && card.dataset.card)
                    openCards.add(card.dataset.card);
            });
        }
        this.root.innerHTML = `<main class="settings-sidebar">
            <header class="sidebar-heading">${icon("diagram-3-fill")}<div><strong>Autonom</strong><small>Workspace control center</small></div></header>
            <button type="button" class="primary sidebar-open" data-action="open">${icon("box-arrow-up-right")}Open workspace</button>
            <div class="control-card"><div class="control-summary"><span id="connection-dot" class="dot"></span><span id="connection-label">Connecting</span><span class="badge">:${settings.port}</span></div></div>
            <details class="control-card" data-card="workspace" open><summary>${icon("folder2-open")}Workspace${icon("chevron-right", "disclosure")}</summary>
                <div class="control-content"><p><strong>${escape(state.workspaceName || "No folder open")}</strong><br>${config?.installed ? "Hooks and MCP configured." : "Install hooks, MCP, and a default policy to get started."}</p>
                <div class="control-actions"><button class="secondary" type="button" data-action="setup">${icon("check-circle")}Set up</button><button class="secondary" type="button" data-action="newSession">${icon("plus-lg")}Session</button></div></div></details>
            <details class="control-card" data-card="connection" open><summary>${icon("sliders")}Connection &amp; defaults${icon("chevron-right", "disclosure")}</summary>
                <form id="connection-form" class="control-content">
                    <label class="field">Autonom repository<input name="rootDirectory" value="${escape(settings.rootDirectory)}" required></label>
                    <label class="field">Daemon config file<input name="configFile" value="${escape(settings.configFile)}" required></label>
                    <label class="field">Port<input name="port" type="number" min="1" max="65535" value="${settings.port}" required></label>
                    <label class="field">Default model<input name="defaultModel" value="${escape(settings.defaultModel)}" required></label>
                    <label class="field">Permission mode<select name="permissionMode">${modeOptions(settings.permissionMode)}</select></label>
                    <label class="field">Refresh interval (ms)<input name="pollIntervalMs" type="number" min="500" max="10000" value="${settings.pollIntervalMs}" required></label>
                    <label class="check-row"><input type="checkbox" name="notifyPings" ${settings.notifyPings ? "checked" : ""}>Notify me about pings</label>
                    <button type="submit" class="primary">Save settings</button>
                </form></details>
            <details class="control-card" data-card="daemon"><summary>${icon("clock")}Daemon &amp; scheduling${icon("chevron-right", "disclosure")}</summary>
                <form id="daemon-form" class="control-content"><p>Settings take effect the next time the daemon starts. Saving does not interrupt active agents.</p>
                    <label class="field">Devin command<input name="devinCommand" value="${value("devinCommand", "devin")}" required></label>
                    <label class="field">Fresh start after<input name="offlineStartAfter" value="${value("offlineStartAfter", "1h")}" required><small>For unscheduled agent pings.</small></label>
                    <label class="field">Compact after<input name="offlineCompactAfter" value="${value("offlineCompactAfter", "1h")}" required></label>
                    <label class="field">Compaction thresholds<input name="compactionThresholds" value="${value("compactionThresholds", "1,2,3")}" required></label>
                    <label class="field">Run timeout<input name="executionTimeout" value="${value("executionTimeout", "30m")}" required></label>
                    <label class="check-row"><input type="checkbox" name="compactOnResume" ${daemon.compactOnResume ? "checked" : ""}>Compact before every resume</label>
                    <button class="primary" type="submit">Save daemon settings</button>
                    <button class="secondary" type="button" data-action="editConfig">${icon("file-earmark-text")}Edit YAML</button>
                </form></details>
            <details class="control-card" data-card="policy"><summary>${icon("shield-check")}Workspace policy${icon("chevron-right", "disclosure")}</summary>
                <form id="policy-form" class="control-content"><p>Every tool call is screened before execution, including bypass mode. Invalid policies fail closed.</p>
                    <label class="field">.devin/policy.yml<textarea name="policy" spellcheck="false" required>${escape(config?.policy ?? "")}</textarea></label>
                    <div class="control-actions"><button class="primary" type="submit">Save policy</button><button class="secondary" type="button" data-action="editPolicy">${icon("pencil")}Edit</button></div>
                </form></details>
            <details class="control-card" data-card="backend"><summary>${icon("key")}Decision backend${icon("chevron-right", "disclosure")}</summary>
                <div class="control-content"><p>${config?.routerConfigured ? "OpenRouter is configured." : "OpenRouter needs a key in your daemon config."} The key stays in the extension host and is never sent to this panel.</p>
                <button class="secondary" type="button" data-action="configureKey">Configure OpenRouter key</button></div></details>
            <p class="sidebar-notice">Only sessions launched by Autonom can use its coordination tools. Desktop agent-panel sessions are not supported.</p>
            <button class="secondary" type="button" data-action="refresh">${icon("arrow-clockwise")}Reload configuration</button>
        </main>`;
        if (hadCards)
        {
            this.root.querySelectorAll<HTMLDetailsElement>("details.control-card").forEach((card) =>
            {
                if (card.dataset.card)
                    card.open = openCards.has(card.dataset.card);
            });
        }
        this.updateConnection(state);
    }

    private updateConnection(state: ViewState): void
    {
        const dot = document.getElementById("connection-dot");
        const label = document.getElementById("connection-label");
        if (dot !== null)
            dot.className = "dot " + (state.connected ? "online" : "failed");
        if (label !== null)
        {
            label.textContent = state.connected ? "Daemon connected" : "Disconnected";
            label.title = state.error;
        }
    }
}
