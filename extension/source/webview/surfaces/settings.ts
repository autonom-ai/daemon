import { escape, icon } from "../dom";
import type { ConfigurationState, DaemonState, Settings } from "../../protocol";
import { bridge } from "../bridge";

export class SettingsSurface {
    private container: HTMLElement;
    private policyText = "";
    private policyVersion = "";
    private currentSettings: Partial<Settings> = {};
    private isSavingDaemon = false;
    private isSavingPolicy = false;

    constructor(container: HTMLElement) {
        this.container = container;
    }

    async loadConfig(showToast: (msg: string, isErr?: boolean) => void): Promise<void> {
        try {
            const config = await bridge.request<ConfigurationState>("getPolicy");
            if (config) {
                this.policyText = config.policy || "";
                this.policyVersion = config.policyVersion || "";
            }
            const settings = await bridge.request<Settings>("getSettings");
            if (settings) {
                this.currentSettings = settings;
            }
        } catch (err: any) {
            showToast(err?.message || "Could not load settings", true);
        }
    }

    render(
        _state: DaemonState,
        providerMode: string,
        onRefresh: () => void,
        showToast: (msg: string, isErr?: boolean) => void,
        onProviderToggle: (nextMode: "autonom" | "devin-cloud") => void,
    ): void {
        const s = this.currentSettings;

        const html = `
            <div class="surface-container settings-surface" data-surface="settings">
                <div class="surface-header">
                    <div class="surface-title-group">
                        <span class="surface-icon">${icon("gear")}</span>
                        <h2>Settings & Policy</h2>
                    </div>
                </div>

                <div class="settings-grid">
                    <!-- Provider Mode Section -->
                    <div class="settings-card">
                        <div class="card-header">
                            <h3>Command Center Provider</h3>
                            <span class="badge ${providerMode === "autonom" ? "badge-success" : ""}">${escape(providerMode)}</span>
                        </div>
                        <p class="card-description muted">
                            Toggle between local autonomous agent orchestration (Autonom) and remote cloud execution (Devin Cloud).
                        </p>
                        <div class="provider-toggle-row">
                            <button class="secondary ${providerMode === "autonom" ? "active" : ""}" id="btn-set-autonom" type="button">
                                <span>Autonom (Local)</span>
                            </button>
                            <button class="secondary ${providerMode === "devin-cloud" ? "active" : ""}" id="btn-set-devin-cloud" type="button">
                                <span>Devin Cloud</span>
                            </button>
                        </div>
                    </div>

                    <!-- Daemon Scheduling Settings -->
                    <div class="settings-card">
                        <div class="card-header">
                            <h3>Daemon Scheduling & Lifecycle</h3>
                        </div>
                        <p class="card-description muted">
                            Configure idle wake timeouts, automatic compaction, and poll intervals for autonomous agents.
                        </p>
                        <div class="settings-form">
                            <div class="form-row-grid">
                                <div class="form-field">
                                    <label for="input-poll-interval">Poll Interval (ms)</label>
                                    <input type="number" id="input-poll-interval" value="${s.pollIntervalMs || 1000}" min="500" max="10000" step="100" />
                                </div>
                                <div class="form-field">
                                    <label for="input-offline-start">Offline Start After</label>
                                    <input type="text" id="input-offline-start" value="${escape(s.offlineStartAfter || "1h")}" placeholder="e.g. 1h, 30m" />
                                </div>
                                <div class="form-field">
                                    <label for="input-offline-compact">Offline Compact After</label>
                                    <input type="text" id="input-offline-compact" value="${escape(s.offlineCompactAfter || "1h")}" placeholder="e.g. 1h, 30m" />
                                </div>
                                <div class="form-field">
                                    <label for="input-compaction-thresholds">Compaction Thresholds</label>
                                    <input type="text" id="input-compaction-thresholds" value="${escape(s.compactionThresholds || "1,2,3")}" placeholder="e.g. 1,2,3" />
                                </div>
                            </div>

                            <div class="form-field checkbox-field">
                                <label class="checkbox-label">
                                    <input type="checkbox" id="check-compact-on-resume" ${s.compactOnResume ? "checked" : ""} />
                                    <span>Force compaction before every session resume</span>
                                </label>
                            </div>

                            <div class="button-row">
                                <button class="primary" id="btn-save-daemon-settings" type="button" ${this.isSavingDaemon ? "disabled" : ""}>
                                    ${icon("check")}
                                    <span>${this.isSavingDaemon ? "Saving..." : "Save Daemon Settings"}</span>
                                </button>
                            </div>
                        </div>
                    </div>

                    <!-- Workspace Policy Editor -->
                    <div class="settings-card full-width">
                        <div class="card-header">
                            <h3>Workspace Security Policy (<code>.devin/policy.yml</code>)</h3>
                        </div>
                        <p class="card-description muted">
                            Tool calls from all autonomous sessions are screened against these rules via the PreToolUse hook.
                        </p>
                        <div class="policy-editor-box">
                            <textarea id="textarea-policy-yml" rows="10" spellcheck="false">${escape(this.policyText)}</textarea>
                        </div>
                        <div class="button-row">
                            <button class="primary" id="btn-save-policy" type="button" ${this.isSavingPolicy ? "disabled" : ""}>
                                ${icon("check")}
                                <span>${this.isSavingPolicy ? "Saving Policy..." : "Save Policy"}</span>
                            </button>
                            <button class="secondary" id="btn-edit-command-center-json" type="button">
                                <span>Edit commandCenter.json</span>
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        `;

        this.container.innerHTML = html;

        // Wire Provider buttons
        const btnAutonom = this.container.querySelector("#btn-set-autonom");
        const btnDevin = this.container.querySelector("#btn-set-devin-cloud");
        if (btnAutonom) {
            btnAutonom.addEventListener("click", () => onProviderToggle("autonom"));
        }
        if (btnDevin) {
            btnDevin.addEventListener("click", () => onProviderToggle("devin-cloud"));
        }

        // Wire Daemon settings save
        const btnSaveDaemon = this.container.querySelector("#btn-save-daemon-settings");
        if (btnSaveDaemon) {
            btnSaveDaemon.addEventListener("click", async () => {
                const pollInput = this.container.querySelector("#input-poll-interval") as HTMLInputElement;
                const offlineStart = (this.container.querySelector("#input-offline-start") as HTMLInputElement)?.value.trim();
                const offlineCompact = (this.container.querySelector("#input-offline-compact") as HTMLInputElement)?.value.trim();
                const thresholds = (this.container.querySelector("#input-compaction-thresholds") as HTMLInputElement)?.value.trim();
                const compactOnResume = (this.container.querySelector("#check-compact-on-resume") as HTMLInputElement)?.checked;

                const pollIntervalMs = parseInt(pollInput?.value || "1000", 10);
                if (isNaN(pollIntervalMs) || pollIntervalMs < 500 || pollIntervalMs > 10000) {
                    showToast("Poll interval must be between 500ms and 10000ms", true);
                    return;
                }

                this.isSavingDaemon = true;
                btnSaveDaemon.setAttribute("disabled", "true");

                try {
                    await bridge.request("saveSettings", {
                        settings: {
                            pollIntervalMs,
                            offlineStartAfter: offlineStart,
                            offlineCompactAfter: offlineCompact,
                            compactionThresholds: thresholds,
                            compactOnResume,
                        },
                    });
                    showToast("Daemon settings saved successfully");
                    await this.loadConfig(showToast);
                    onRefresh();
                } catch (err: any) {
                    showToast(err?.message || "Failed to save daemon settings", true);
                } finally {
                    this.isSavingDaemon = false;
                    btnSaveDaemon.removeAttribute("disabled");
                }
            });
        }

        // Wire Policy save
        const btnSavePolicy = this.container.querySelector("#btn-save-policy");
        const policyArea = this.container.querySelector("#textarea-policy-yml") as HTMLTextAreaElement;
        if (btnSavePolicy && policyArea) {
            btnSavePolicy.addEventListener("click", async () => {
                const text = policyArea.value;
                this.isSavingPolicy = true;
                btnSavePolicy.setAttribute("disabled", "true");

                try {
                    await bridge.request("savePolicy", {
                        text,
                        version: this.policyVersion,
                    });
                    showToast("Workspace policy updated successfully");
                    await this.loadConfig(showToast);
                    onRefresh();
                } catch (err: any) {
                    showToast(err?.message || "Failed to save policy", true);
                } finally {
                    this.isSavingPolicy = false;
                    btnSavePolicy.removeAttribute("disabled");
                }
            });
        }

        // Wire Edit commandCenter.json
        const btnEditConfig = this.container.querySelector("#btn-edit-command-center-json");
        if (btnEditConfig) {
            btnEditConfig.addEventListener("click", async () => {
                try {
                    await bridge.request("editConfig");
                } catch (err: any) {
                    showToast(err?.message || "Could not open config file", true);
                }
            });
        }
    }
}
