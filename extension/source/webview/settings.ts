import { bridge, field, toast } from "./bridge";
import { escape, modeOptions, modelOptions } from "./dom";
import type { Settings, ViewState } from "../protocol";

export interface ValidationResult {
    valid: boolean;
    errors: Record<string, string>;
}

export function validateSettings(form: HTMLFormElement): ValidationResult {
    const errors: Record<string, string> = {};

    // 1. Port Validation (1 - 65535, integer)
    const portRaw = field(form, "port").trim();
    if (portRaw) {
        const port = Number(portRaw);
        if (!Number.isInteger(port) || port < 1 || port > 65535) {
            errors["port"] = "Port must be an integer between 1 and 65535.";
        }
    }

    // 2. Refresh Interval (500 - 10000 ms, integer)
    const pollRaw = field(form, "pollIntervalMs").trim();
    if (pollRaw) {
        const pollInterval = Number(pollRaw);
        if (!Number.isInteger(pollInterval) || pollInterval < 500 || pollInterval > 10000) {
            errors["pollIntervalMs"] = "Refresh interval must be an integer between 500 and 10000 ms.";
        }
    }

    // 3. Path Validation
    const rootDir = field(form, "rootDirectory").trim();
    if (form.elements.namedItem("rootDirectory") && !rootDir) {
        errors["rootDirectory"] = "Autonom repository path is required.";
    }

    const configFile = field(form, "configFile").trim();
    if (form.elements.namedItem("configFile") && !configFile) {
        errors["configFile"] = "Daemon configuration file path is required.";
    }

    // 4. Duration Validation (e.g. 30m, 1h, 24h, or integer seconds)
    const durationRegex = /^(\d+(?:ms|s|m|h|d))+$|^\d+$/;
    const timeout = field(form, "executionTimeout").trim();
    if (timeout && !durationRegex.test(timeout)) {
        errors["executionTimeout"] = "Timeout format invalid (use e.g. 30m, 1h, or integer seconds).";
    }

    const startAfter = field(form, "offlineStartAfter").trim();
    if (startAfter && !durationRegex.test(startAfter)) {
        errors["offlineStartAfter"] = "Fresh start timeout invalid (use e.g. 1h or integer seconds).";
    }

    const compactAfter = field(form, "offlineCompactAfter").trim();
    if (compactAfter && !durationRegex.test(compactAfter)) {
        errors["offlineCompactAfter"] = "Compaction timeout invalid (use e.g. 1h or integer seconds).";
    }

    // 5. Compaction Thresholds
    const thresholds = field(form, "compactionThresholds").trim();
    if (thresholds && !/^\d+(\s*,\s*\d+)*$/.test(thresholds)) {
        errors["compactionThresholds"] = "Compaction thresholds must be comma-separated integers.";
    }

    return {
        valid: Object.keys(errors).length === 0,
        errors,
    };
}

export class SettingsView {
    private container: HTMLElement;
    private state: ViewState | undefined;
    private dirty = false;
    private signature = "";
    private onBack: (() => void) | undefined;

    constructor(container: HTMLElement, onBack?: () => void) {
        this.container = container;
        this.onBack = onBack;

        container.addEventListener("input", () => { this.dirty = true; });

        container.addEventListener("click", (event) => {
            const button = (event.target as Element).closest<HTMLButtonElement>("[data-action]");
            const action = button?.dataset.action;
            if (action === "setup" || action === "editPolicy" || action === "editConfig" || action === "configureKey") {
                bridge.postMessage({ type: action });
            }
            if (action === "closeSettings" || action === "back" || action === "backToChat") {
                this.onBack?.();
            }
            if (action === "refresh") {
                this.dirty = false;
                this.signature = "";
                bridge.postMessage({ type: "refresh" });
            }
        });

        container.addEventListener("submit", (event) => {
            event.preventDefault();
            const form = event.target as HTMLFormElement;

            // Card 1: Connection & Models
            if (form.id === "connection-form") {
                const validation = validateSettings(form);
                if (!validation.valid) {
                    const firstError = Object.values(validation.errors)[0] || "Invalid settings";
                    toast(firstError, true);
                    const firstKey = Object.keys(validation.errors)[0];
                    if (firstKey) {
                        (form.elements.namedItem(firstKey) as HTMLInputElement | null)?.focus();
                    }
                    return;
                }

                const rootDirectory = field(form, "rootDirectory").trim();
                const configFile = field(form, "configFile").trim();
                const port = Number(field(form, "port").trim());
                const pollIntervalMs = Number(field(form, "pollIntervalMs").trim());

                const settings: Settings = {
                    rootDirectory,
                    configFile,
                    port,
                    defaultModel: field(form, "defaultModel") || "swe-2-medium",
                    permissionMode: field(form, "permissionMode") as Settings["permissionMode"],
                    pollIntervalMs,
                    notifyPings: new FormData(form).has("notifyPings"),
                };
                bridge.postMessage({ type: "saveSettings", settings });
            }

            // Card 3: Daemon Parameters
            if (form.id === "daemon-form") {
                const validation = validateSettings(form);
                if (!validation.valid) {
                    const firstError = Object.values(validation.errors)[0] || "Invalid daemon parameters";
                    toast(firstError, true);
                    const firstKey = Object.keys(validation.errors)[0];
                    if (firstKey) {
                        (form.elements.namedItem(firstKey) as HTMLInputElement | null)?.focus();
                    }
                    return;
                }

                bridge.postMessage({
                    type: "saveDaemon",
                    values: {
                        devinCommand: field(form, "devinCommand").trim(),
                        offlineStartAfter: field(form, "offlineStartAfter").trim(),
                        offlineCompactAfter: field(form, "offlineCompactAfter").trim(),
                        compactionThresholds: field(form, "compactionThresholds").trim(),
                        executionTimeout: field(form, "executionTimeout").trim(),
                        compactOnResume: new FormData(form).has("compactOnResume"),
                    },
                });
            }

            // Card 4: Workspace Safety Policy Rules
            if (form.id === "policy-form") {
                bridge.postMessage({
                    type: "savePolicy",
                    text: field(form, "policy"),
                    version: this.state?.configuration?.policyVersion ?? "",
                });
            }
        });
    }

    render(state: ViewState | undefined): void {
        if (state === undefined) return;
        this.state = state;

        const signature = JSON.stringify([state.settings, state.configuration, state.connected]);
        if (this.dirty || signature === this.signature) return;
        this.signature = signature;

        const settings = state.settings;
        const config = state.configuration;
        const daemon = config?.daemon ?? {};
        const daemonVal = (key: string, fallback: string): string => escape(daemon[key] ?? fallback);

        this.container.innerHTML = `
            <div class="settings-dashboard" id="settings-dashboard">
                <header class="settings-banner">
                    <div>
                        <h2>Autonom Command Center Settings</h2>
                        <p class="muted">Manage loopback daemon parameters, OpenRouter credentials, lifecycle durations, and workspace safety policy.</p>
                    </div>
                    <div class="settings-banner-actions">
                        <button type="button" class="secondary" data-action="back" aria-label="Back to conversation">
                            <span class="codicon codicon-arrow-left" aria-hidden="true"></span>Back
                        </button>
                        <button type="button" class="secondary" data-action="refresh">
                            <span class="codicon codicon-refresh" aria-hidden="true"></span>Reload
                        </button>
                    </div>
                </header>

                <div class="settings-grid">
                    <!-- CARD 1: Daemon Connection & Model Defaults -->
                    <section class="settings-card" id="card-connection" data-card="connection">
                        <header class="settings-card-header">
                            <span class="settings-card-icon"><span class="codicon codicon-settings" aria-hidden="true"></span></span>
                            <div>
                                <h3>Daemon Connection &amp; Models</h3>
                                <p class="muted">Loopback port, repository paths, and default model selection.</p>
                            </div>
                        </header>
                        <form id="connection-form" class="settings-card-body" novalidate>
                            <label class="field">Autonom repository path
                                <input name="rootDirectory" value="${escape(settings.rootDirectory)}" required spellcheck="false">
                                <small>Directory containing bin/autonom-daemon and source/coord/server.py.</small>
                            </label>
                            <label class="field">Daemon configuration file
                                <input name="configFile" value="${escape(settings.configFile)}" required spellcheck="false">
                            </label>
                            <div class="field-row">
                                <label class="field">Port
                                    <input name="port" type="number" min="1" max="65535" value="${settings.port}" required>
                                </label>
                                <label class="field">Refresh interval (ms)
                                    <input name="pollIntervalMs" type="number" min="500" max="10000" value="${settings.pollIntervalMs}" required>
                                </label>
                            </div>
                            <div class="field-row">
                                <label class="field">Default model
                                    <select name="defaultModel">
                                        ${modelOptions(state.models, settings.defaultModel || "swe-2-medium")}
                                    </select>
                                </label>
                                <label class="field">Default permission mode
                                    <select name="permissionMode">
                                        ${modeOptions(settings.permissionMode)}
                                    </select>
                                </label>
                            </div>
                            <label class="check-row">
                                <input type="checkbox" name="notifyPings" ${settings.notifyPings ? "checked" : ""}>
                                Notify me about agent pings via desktop notifications
                            </label>
                            <footer class="card-footer">
                                <button type="submit" class="primary">Save connection settings</button>
                            </footer>
                        </form>
                    </section>

                    <!-- CARD 2: Decision Backend & Routing -->
                    <section class="settings-card" id="card-routing" data-card="routing">
                        <header class="settings-card-header">
                            <span class="settings-card-icon"><span class="codicon codicon-key" aria-hidden="true"></span></span>
                            <div>
                                <h3>Decision Backend &amp; Routing</h3>
                                <p class="muted">OpenRouter authentication for Mercury decision screening.</p>
                            </div>
                        </header>
                        <div class="settings-card-body">
                            <div class="info-callout ${config?.routerConfigured ? "success" : "warning"}">
                                <span class="codicon codicon-${config?.routerConfigured ? "check" : "warning"}" aria-hidden="true"></span>
                                <div>
                                    <strong>${config?.routerConfigured ? "OpenRouter is configured" : "OpenRouter key required"}</strong>
                                    <p>${config?.routerConfigured ? "The daemon has an active API key for policy screening." : "Screens require an OpenRouter key in your daemon config."}</p>
                                </div>
                            </div>
                            <label class="field">Router API Key (masked)
                                <input type="password" name="routerKey" placeholder="••••••••••••••••" readonly>
                            </label>
                            <p class="card-notice">Keys are stored privately on disk (mode 0600) and never sent to the webview.</p>
                            <footer class="card-footer">
                                <button type="button" class="primary" data-action="configureKey">
                                    <span class="codicon codicon-key" aria-hidden="true"></span>Configure OpenRouter key
                                </button>
                            </footer>
                        </div>
                    </section>

                    <!-- CARD 3: Daemon Lifecycle & Compaction Timeouts -->
                    <section class="settings-card" id="card-lifecycle" data-card="lifecycle">
                        <header class="settings-card-header">
                            <span class="settings-card-icon"><span class="codicon codicon-history" aria-hidden="true"></span></span>
                            <div>
                                <h3>Daemon Lifecycle &amp; Timeouts</h3>
                                <p class="muted">Process execution timeouts, compaction thresholds, and offline wake intervals.</p>
                            </div>
                        </header>
                        <form id="daemon-form" class="settings-card-body">
                            <div class="field-row">
                                <label class="field">Devin CLI command
                                    <input name="devinCommand" value="${daemonVal("devinCommand", "devin")}" required>
                                </label>
                                <label class="field">Execution run timeout
                                    <input name="executionTimeout" value="${daemonVal("executionTimeout", "30m")}" required>
                                </label>
                            </div>
                            <div class="field-row">
                                <label class="field">Fresh start after (unscheduled pings)
                                    <input name="offlineStartAfter" value="${daemonVal("offlineStartAfter", "1h")}" required>
                                </label>
                                <label class="field">Compact after
                                    <input name="offlineCompactAfter" value="${daemonVal("offlineCompactAfter", "1h")}" required>
                                </label>
                            </div>
                            <label class="field">Compaction thresholds
                                <input name="compactionThresholds" value="${daemonVal("compactionThresholds", "1,2,3")}" required>
                                <small>Positive token count levels separated by commas.</small>
                            </label>
                            <label class="check-row">
                                <input type="checkbox" name="compactOnResume" ${daemon.compactOnResume ? "checked" : ""}>
                                Force compaction before every resume turn
                            </label>
                            <footer class="card-footer">
                                <button type="submit" class="primary">Save daemon parameters</button>
                                <button type="button" class="secondary" data-action="editConfig">
                                    <span class="codicon codicon-file-code" aria-hidden="true"></span>Edit YAML
                                </button>
                            </footer>
                        </form>
                    </section>

                    <!-- CARD 4: Workspace Safety Policy Rules -->
                    <section class="settings-card card-span-2" id="card-policy" data-card="policy">
                        <header class="settings-card-header">
                            <span class="settings-card-icon"><span class="codicon codicon-shield" aria-hidden="true"></span></span>
                            <div>
                                <h3>Workspace Policy Rules (.devin/policy.yml)</h3>
                                <p class="muted">Every tool call is screened by this policy before execution, including in bypass mode.</p>
                            </div>
                        </header>
                        <form id="policy-form" class="settings-card-body">
                            <label class="field">
                                Policy rules YAML
                                <textarea name="policy" class="policy-code-editor" spellcheck="false" required rows="8">${escape(config?.policy ?? "")}</textarea>
                            </label>
                            <footer class="card-footer">
                                <button type="submit" class="primary">Save workspace policy</button>
                                <button type="button" class="secondary" data-action="editPolicy">
                                    <span class="codicon codicon-edit" aria-hidden="true"></span>Open in editor
                                </button>
                            </footer>
                        </form>
                    </section>

                    <!-- CARD 5: Workspace Integration Status -->
                    <section class="settings-card card-span-2" id="card-setup" data-card="setup">
                        <header class="settings-card-header">
                            <span class="settings-card-icon"><span class="codicon codicon-folder" aria-hidden="true"></span></span>
                            <div>
                                <h3>Workspace Setup &amp; MCP Integration</h3>
                                <p class="muted">Ensures hooks (.devin/hooks.v1.json) and MCP server (.devin/mcp_config.json) are active.</p>
                            </div>
                        </header>
                        <div class="settings-card-body">
                            <div class="info-callout ${config?.installed ? "success" : "warning"}">
                                <span class="codicon codicon-${config?.installed ? "check" : "warning"}" aria-hidden="true"></span>
                                <div>
                                    <strong>${config?.installed ? "Workspace integration installed" : "Workspace not set up"}</strong>
                                    <p>${config?.installed ? "Autonom hooks forward PreToolUse and MCP coordination server is configured." : "Click below to install required hooks and MCP server in this workspace."}</p>
                                </div>
                            </div>
                            <footer class="card-footer">
                                <button type="button" class="secondary" data-action="setup">
                                    <span class="codicon codicon-check" aria-hidden="true"></span>Reinstall Autonom integration
                                </button>
                            </footer>
                        </div>
                    </section>
                </div>
            </div>`;
    }

    saved(action: string, ok: boolean): void {
        if (ok) {
            this.dirty = false;
            this.signature = "";
            const messages: Record<string, string> = {
                saveSettings: "Settings saved.",
                savePolicy: "Settings saved. Tool screening rules apply immediately.",
                saveDaemon: "Settings saved. Daemon settings updated.",
                setup: "Workspace setup complete.",
                configureKey: "OpenRouter key configured.",
            };
            toast(messages[action] || "Settings saved.");
        }
    }
}
