import { escape, icon, modeOptions, modelOptions } from "../dom";
import type { DaemonState, Execution, Model, PermissionMode } from "../../protocol";
import { bridge } from "../bridge";

export class ComposerSurface {
    private container: HTMLElement;
    private selectedModel = "swe-2-medium";
    private selectedMode: PermissionMode = "bypass";
    private selectedProfile = "";
    private isSubmitting = false;

    constructor(container: HTMLElement) {
        this.container = container;
    }

    render(
        state: DaemonState,
        models: Model[],
        workspace: string,
        onRefresh: () => void,
        showToast: (msg: string, isErr?: boolean) => void,
        onSessionStarted: () => void,
    ): void {
        const profiles = (state.profiles || []).filter((p) => p.name.toLowerCase() !== "human");

        const html = `
            <div class="surface-container composer-surface" data-surface="composer">
                <div class="composer-card">
                    <div class="composer-header">
                        <div class="composer-title-group">
                            <span class="composer-icon">${icon("terminal")}</span>
                            <h2>Launch Autonomous Agent</h2>
                        </div>
                        <span class="badge composer-badge">Autonom Engine</span>
                    </div>

                    <div class="composer-form">
                        <div class="form-row-grid">
                            <!-- Model Picker -->
                            <div class="form-field">
                                <label for="select-composer-model">Model</label>
                                <select id="select-composer-model" class="native-select">
                                    ${modelOptions(models, this.selectedModel)}
                                </select>
                            </div>

                            <!-- Permission Mode -->
                            <div class="form-field">
                                <label for="select-composer-mode">Permission Mode</label>
                                <select id="select-composer-mode" class="native-select">
                                    ${modeOptions(this.selectedMode)}
                                </select>
                            </div>

                            <!-- Profile Assignment -->
                            <div class="form-field">
                                <label for="select-composer-profile">Assign Profile (Optional)</label>
                                <select id="select-composer-profile" class="native-select">
                                    <option value="" ${!this.selectedProfile ? "selected" : ""}>None (unbound session)</option>
                                    ${profiles.map((p) => `
                                        <option value="${escape(p.name)}" ${this.selectedProfile === p.name ? "selected" : ""}>@${escape(p.name)}</option>
                                    `).join("")}
                                </select>
                            </div>
                        </div>

                        <!-- Working Directory -->
                        <div class="form-field full-width">
                            <label for="input-composer-dir">Working Directory</label>
                            <input type="text" id="input-composer-dir" value="${escape(workspace || "")}" placeholder="Absolute workspace path" />
                        </div>

                        <!-- Prompt Input -->
                        <div class="form-field full-width">
                            <label for="textarea-composer-prompt">Initial Prompt / Instructions</label>
                            <textarea id="textarea-composer-prompt" placeholder="What task should this agent execute?" rows="6" required></textarea>
                        </div>

                        <!-- Submit Action -->
                        <div class="composer-actions">
                            <div class="composer-hint muted">
                                <span>Default: SWE-2 Medium with bypass mode screened by workspace policy.</span>
                            </div>
                            <button class="primary launch-button" id="btn-launch-session" type="button" ${this.isSubmitting ? "disabled" : ""}>
                                ${icon(this.isSubmitting ? "arrow-repeat" : "play")}
                                <span>${this.isSubmitting ? "Launching..." : "Start Session"}</span>
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        `;

        this.container.innerHTML = html;

        // Model select listener
        const modelSelect = this.container.querySelector("#select-composer-model") as HTMLSelectElement;
        if (modelSelect) {
            modelSelect.addEventListener("change", () => {
                this.selectedModel = modelSelect.value;
            });
        }

        // Mode select listener
        const modeSelect = this.container.querySelector("#select-composer-mode") as HTMLSelectElement;
        if (modeSelect) {
            modeSelect.addEventListener("change", () => {
                this.selectedMode = modeSelect.value as PermissionMode;
            });
        }

        // Profile select listener
        const profileSelect = this.container.querySelector("#select-composer-profile") as HTMLSelectElement;
        if (profileSelect) {
            profileSelect.addEventListener("change", () => {
                this.selectedProfile = profileSelect.value;
            });
        }

        // Launch button
        const launchBtn = this.container.querySelector("#btn-launch-session");
        const promptArea = this.container.querySelector("#textarea-composer-prompt") as HTMLTextAreaElement;
        const dirInput = this.container.querySelector("#input-composer-dir") as HTMLInputElement;

        if (launchBtn && promptArea && dirInput) {
            launchBtn.addEventListener("click", async () => {
                const prompt = promptArea.value.trim();
                const directory = dirInput.value.trim();
                if (!prompt) {
                    showToast("Please enter an initial prompt", true);
                    promptArea.focus();
                    return;
                }

                this.isSubmitting = true;
                this.render(state, models, workspace, onRefresh, showToast, onSessionStarted);

                try {
                    const exec = await bridge.request<Execution>("startSession", {
                        prompt,
                        directory,
                        model: this.selectedModel,
                        mode: this.selectedMode,
                        profile: this.selectedProfile,
                    });

                    showToast(`Session launch queued (execution ${exec.id})`);

                    // Poll execution status
                    let attempts = 0;
                    const poll = setInterval(async () => {
                        attempts++;
                        try {
                            const cur = await bridge.request<Execution>("getExecution", { id: exec.id });
                            if (cur.sessionId || cur.status !== "running" || attempts > 15) {
                                clearInterval(poll);
                                this.isSubmitting = false;
                                if (cur.sessionId) {
                                    showToast(`Session ${cur.sessionId} started successfully!`);
                                } else if (cur.status === "succeeded") {
                                    showToast("Execution completed successfully");
                                } else if (cur.error) {
                                    showToast(`Session start error: ${cur.error}`, true);
                                }
                                onRefresh();
                                onSessionStarted();
                            }
                        } catch {
                            clearInterval(poll);
                            this.isSubmitting = false;
                            onRefresh();
                        }
                    }, 1000);
                } catch (err: any) {
                    this.isSubmitting = false;
                    showToast(err?.message || "Failed to start session", true);
                    this.render(state, models, workspace, onRefresh, showToast, onSessionStarted);
                }
            });
        }
    }
}
