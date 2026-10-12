import { escape } from "./dom";
import type { Destination, PermissionMode, ViewState } from "../protocol";

export interface ModelInfo {
    id: string;
    label: string;
    family: string;
    cost?: string;
}

export const DEFAULT_MODEL_ID = "swe-2-medium";
export const DEFAULT_MODEL_LABEL = "SWE-2 Medium";

export const PERMISSION_MODES: { value: PermissionMode; label: string; description: string }[] = [
    { value: "auto", label: "Ask permissions", description: "Prompt for approval on risky tools" },
    { value: "accept-edits", label: "Accept edits", description: "Auto-approve file changes" },
    { value: "smart", label: "Smart", description: "Screen tool calls with Mercury safety policy" },
    { value: "bypass", label: "Bypass permissions", description: "Skip manual prompts, policy screens still apply" },
];

/**
 * Native Composer Component for Devin Desktop Command Center
 * Preserves Devin's native composer styling, toolbar, and model picker popover.
 * Eliminates mock HTML <select> dropdowns and alien Bootstrap icons; uses VS Code Codicons & native SVGs.
 * Defaults strictly to swe-2-medium (SWE-2).
 */
export class ComposerView {
    private form: HTMLFormElement;
    private selectedModel = DEFAULT_MODEL_ID;
    private selectedMode: PermissionMode = "auto";
    private state: ViewState | undefined;

    private modelBtn: HTMLButtonElement | null = null;
    private modeBtn: HTMLButtonElement | null = null;
    private modelPopover: HTMLElement | null = null;
    private modePopover: HTMLElement | null = null;
    private hiddenModelInput: HTMLInputElement | null = null;
    private hiddenModeInput: HTMLInputElement | null = null;
    private sendBtn: HTMLButtonElement | null = null;
    private textarea: HTMLTextAreaElement | null = null;
    private caption: HTMLElement | null = null;

    constructor(form: HTMLFormElement) {
        this.form = form;
        this.setupDOM();
        this.bindEvents();
    }

    private setupDOM(): void {
        this.textarea = this.form.querySelector<HTMLTextAreaElement>("#composer-text");
        this.caption = this.form.querySelector<HTMLElement>("#composer-caption");
        this.sendBtn = this.form.querySelector<HTMLButtonElement>("#send-button");

        // Hidden inputs for form data compatibility
        this.hiddenModelInput = document.createElement("input");
        this.hiddenModelInput.type = "hidden";
        this.hiddenModelInput.name = "model";
        this.hiddenModelInput.id = "composer-model";
        this.hiddenModelInput.value = this.selectedModel;

        this.hiddenModeInput = document.createElement("input");
        this.hiddenModeInput.type = "hidden";
        this.hiddenModeInput.name = "mode";
        this.hiddenModeInput.id = "composer-mode";
        this.hiddenModeInput.value = this.selectedMode;

        this.form.appendChild(this.hiddenModelInput);
        this.form.appendChild(this.hiddenModeInput);

        // Remove old select elements if present
        const oldModelSelect = this.form.querySelector("select#composer-model");
        const oldModeSelect = this.form.querySelector("select#composer-mode");
        oldModelSelect?.remove();
        oldModeSelect?.remove();

        const bottomContainer = this.form.querySelector(".composer-bottom");
        if (bottomContainer) {
            // Container for native toolbar buttons
            const toolbar = document.createElement("div");
            toolbar.className = "composer-native-toolbar";

            // Native Model Selector Trigger
            this.modelBtn = document.createElement("button");
            this.modelBtn.type = "button";
            this.modelBtn.id = "composer-model-btn";
            this.modelBtn.className = "composer-model-trigger";
            this.modelBtn.setAttribute("aria-haspopup", "listbox");
            this.modelBtn.setAttribute("aria-expanded", "false");
            this.modelBtn.innerHTML = `
                <span class="codicon codicon-sparkle model-trigger-icon" aria-hidden="true"></span>
                <span class="model-trigger-name" id="model-trigger-label">${DEFAULT_MODEL_LABEL}</span>
                <span class="codicon codicon-chevron-down trigger-chevron" aria-hidden="true"></span>
            `;

            // Native Permission Mode Trigger
            this.modeBtn = document.createElement("button");
            this.modeBtn.type = "button";
            this.modeBtn.id = "composer-mode-btn";
            this.modeBtn.className = "composer-mode-trigger";
            this.modeBtn.setAttribute("aria-haspopup", "listbox");
            this.modeBtn.setAttribute("aria-expanded", "false");
            this.modeBtn.innerHTML = `
                <span class="codicon codicon-shield trigger-icon" aria-hidden="true"></span>
                <span class="mode-trigger-name" id="mode-trigger-label">Ask permissions</span>
                <span class="codicon codicon-chevron-down trigger-chevron" aria-hidden="true"></span>
            `;

            toolbar.appendChild(this.modelBtn);
            toolbar.appendChild(this.modeBtn);

            // Insert toolbar before composer-hint
            const hint = bottomContainer.querySelector(".composer-hint");
            if (hint) {
                bottomContainer.insertBefore(toolbar, hint);
            } else {
                bottomContainer.insertBefore(toolbar, bottomContainer.firstChild);
            }
        }

        // Create popovers and attach to form
        this.modelPopover = document.createElement("div");
        this.modelPopover.id = "model-picker-popover";
        this.modelPopover.className = "composer-popover model-picker-popover";
        this.modelPopover.setAttribute("role", "listbox");
        this.modelPopover.hidden = true;

        this.modePopover = document.createElement("div");
        this.modePopover.id = "mode-picker-popover";
        this.modePopover.className = "composer-popover mode-picker-popover";
        this.modePopover.setAttribute("role", "listbox");
        this.modePopover.hidden = true;

        this.form.appendChild(this.modelPopover);
        this.form.appendChild(this.modePopover);
    }

    private bindEvents(): void {
        this.modelBtn?.addEventListener("click", (e) => {
            e.stopPropagation();
            this.toggleModelPopover();
        });

        this.modeBtn?.addEventListener("click", (e) => {
            e.stopPropagation();
            this.toggleModePopover();
        });

        document.addEventListener("click", (e) => {
            const target = e.target as Node;
            if (this.modelPopover && !this.modelPopover.contains(target) && this.modelBtn && !this.modelBtn.contains(target)) {
                this.closeModelPopover();
            }
            if (this.modePopover && !this.modePopover.contains(target) && this.modeBtn && !this.modeBtn.contains(target)) {
                this.closeModePopover();
            }
        });

        this.modelPopover?.addEventListener("click", (e) => {
            const item = (e.target as Element).closest<HTMLElement>(".model-picker-item");
            if (item && item.dataset.model) {
                this.selectModel(item.dataset.model);
                this.closeModelPopover();
            }
        });

        this.modePopover?.addEventListener("click", (e) => {
            const item = (e.target as Element).closest<HTMLElement>(".mode-picker-item");
            if (item && item.dataset.mode) {
                this.selectMode(item.dataset.mode as PermissionMode);
                this.closeModePopover();
            }
        });
    }

    private toggleModelPopover(): void {
        if (!this.modelPopover) return;
        this.closeModePopover();
        const isOpen = !this.modelPopover.hidden;
        if (isOpen) {
            this.closeModelPopover();
        } else {
            this.renderModelList();
            this.modelPopover.hidden = false;
            this.modelBtn?.setAttribute("aria-expanded", "true");
        }
    }

    private closeModelPopover(): void {
        if (!this.modelPopover) return;
        this.modelPopover.hidden = true;
        this.modelBtn?.setAttribute("aria-expanded", "false");
    }

    private toggleModePopover(): void {
        if (!this.modePopover) return;
        this.closeModelPopover();
        const isOpen = !this.modePopover.hidden;
        if (isOpen) {
            this.closeModePopover();
        } else {
            this.renderModeList();
            this.modePopover.hidden = false;
            this.modeBtn?.setAttribute("aria-expanded", "true");
        }
    }

    private closeModePopover(): void {
        if (!this.modePopover) return;
        this.modePopover.hidden = true;
        this.modeBtn?.setAttribute("aria-expanded", "false");
    }

    private renderModelList(): void {
        if (!this.modelPopover) return;
        const models: ModelInfo[] = (this.state?.models && this.state.models.length > 0)
            ? this.state.models
            : [{ id: DEFAULT_MODEL_ID, label: DEFAULT_MODEL_LABEL, family: "SWE-2", cost: "Free" }];

        // Group by family
        const families = new Map<string, ModelInfo[]>();
        for (const m of models) {
            const list = families.get(m.family) || [];
            list.push(m);
            families.set(m.family, list);
        }

        let html = '<div class="popover-header"><span class="popover-title">Select Model</span><span class="badge">swe-2-medium default</span></div>';
        html += '<div class="popover-scroll">';

        for (const [family, list] of families.entries()) {
            html += `<div class="popover-group-label">${escape(family)}</div>`;
            for (const m of list) {
                const isSelected = m.id === this.selectedModel;
                html += `
                    <div class="model-picker-item ${isSelected ? "selected" : ""}" role="option" data-model="${escape(m.id)}" aria-selected="${isSelected}">
                        <span class="codicon codicon-check item-check ${isSelected ? "visible" : ""}" aria-hidden="true"></span>
                        <div class="item-text">
                            <span class="item-label">${escape(m.label)}</span>
                            <span class="item-id muted">${escape(m.id)}</span>
                        </div>
                        <span class="item-badge ${m.id === DEFAULT_MODEL_ID ? "badge-free" : ""}">${escape(m.cost || "Free")}</span>
                    </div>
                `;
            }
        }

        html += "</div>";
        this.modelPopover.innerHTML = html;
    }

    private renderModeList(): void {
        if (!this.modePopover) return;
        let html = '<div class="popover-header"><span class="popover-title">Permission Mode</span></div>';
        html += '<div class="popover-scroll">';

        for (const m of PERMISSION_MODES) {
            const isSelected = m.value === this.selectedMode;
            html += `
                <div class="mode-picker-item ${isSelected ? "selected" : ""}" role="option" data-mode="${escape(m.value)}" aria-selected="${isSelected}">
                    <span class="codicon codicon-check item-check ${isSelected ? "visible" : ""}" aria-hidden="true"></span>
                    <div class="item-text">
                        <span class="item-label">${escape(m.label)}</span>
                        <span class="item-desc muted">${escape(m.description)}</span>
                    </div>
                </div>
            `;
        }

        html += "</div>";
        this.modePopover.innerHTML = html;
    }

    public selectModel(modelId: string): void {
        this.selectedModel = modelId || DEFAULT_MODEL_ID;
        if (this.hiddenModelInput) {
            this.hiddenModelInput.value = this.selectedModel;
        }

        const models = this.state?.models || [];
        const found = models.find((m) => m.id === this.selectedModel);
        const label = found ? found.label : (this.selectedModel === DEFAULT_MODEL_ID ? DEFAULT_MODEL_LABEL : this.selectedModel);

        const labelSpan = this.form.querySelector("#model-trigger-label");
        if (labelSpan) {
            labelSpan.textContent = label;
        }
    }

    public selectMode(mode: PermissionMode): void {
        this.selectedMode = mode;
        if (this.hiddenModeInput) {
            this.hiddenModeInput.value = mode;
        }

        const found = PERMISSION_MODES.find((m) => m.value === mode);
        const label = found ? found.label : mode;

        const labelSpan = this.form.querySelector("#mode-trigger-label");
        if (labelSpan) {
            labelSpan.textContent = label;
        }
    }

    public render(
        state: ViewState | undefined,
        selected: Destination | undefined,
        active: boolean,
        submitting: boolean,
        sessionModel?: string,
        sessionMode?: string
    ): void {
        this.state = state;

        if (!this.textarea || !state) return;

        const isAgent = selected?.kind === "session" || selected?.kind === "run";

        this.textarea.disabled = !state.connected || selected === undefined || selected.kind === "pings"
            || submitting || (isAgent && active);
        this.textarea.placeholder = selected === undefined ? "Choose a conversation" : isAgent ? "Ask your agent to do something…"
            : selected.kind === "room" ? `Message #${selected.id} · @profile to ping` : `Message ${selected.id}…`;

        if (this.sendBtn) {
            this.sendBtn.disabled = !state.connected || (!active && this.textarea.disabled);
            this.sendBtn.classList.toggle("stop", active);
            this.sendBtn.innerHTML = active
                ? '<span class="codicon codicon-primitive-square" aria-hidden="true"></span>'
                : '<span class="codicon codicon-arrow-up" aria-hidden="true"></span>';
            this.sendBtn.setAttribute("aria-label", active ? "Stop run" : "Send message");
        }

        // Show/hide triggers based on selection
        if (this.modelBtn) {
            this.modelBtn.hidden = !selected || selected.kind === "pings";
            this.modelBtn.disabled = active;
        }
        if (this.modeBtn) {
            this.modeBtn.hidden = !isAgent;
            this.modeBtn.disabled = active;
        }

        // Resolve model defaulting to swe-2-medium
        const desiredModel = sessionModel || state.settings.defaultModel || DEFAULT_MODEL_ID;
        this.selectModel(desiredModel);

        // Resolve mode
        const desiredMode = (sessionMode === "bypass" || sessionMode === "dangerous") ? "bypass"
            : (["auto", "accept-edits", "smart"].includes(sessionMode || "") ? (sessionMode as PermissionMode)
            : state.settings.permissionMode || "auto");
        this.selectMode(desiredMode);

        if (this.caption) {
            this.caption.textContent = active
                ? "Agent is working. Events interrupt it at its next tool call."
                : selected?.kind === "room" || selected?.kind === "dm"
                    ? "Messages are sent as human. @mentions surface events and wake idle agents."
                    : "Policy screens every tool call. Your conversation stays with the session.";
        }
    }

    public getSelectedModel(): string {
        return this.selectedModel;
    }

    public getSelectedMode(): PermissionMode {
        return this.selectedMode;
    }
}
