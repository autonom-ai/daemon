import { escape, icon } from "./dom";
import type { DaemonState, Model } from "../protocol";
import { emptyDaemon } from "../protocol";
import { bridge } from "./bridge";
import { ProfilesSurface } from "./surfaces/profiles";
import { RoomsSurface } from "./surfaces/rooms";
import { SessionsSurface } from "./surfaces/sessions";
import { ComposerSurface } from "./surfaces/composer";
import { SettingsSurface } from "./surfaces/settings";

export type SurfaceId = "sessions" | "profiles" | "rooms" | "composer" | "settings";

export class AutonomApp {
    private appRoot: HTMLElement;
    private surfaceRoot: HTMLElement | null = null;
    private toastRoot: HTMLElement | null = null;
    private activeSurface: SurfaceId = "sessions";
    private daemonState: DaemonState = emptyDaemon();
    private models: Model[] = [];
    private workspacePath = "";
    private providerMode: "autonom" | "devin-cloud" = "autonom";
    private pollTimer: ReturnType<typeof setInterval> | null = null;

    private profilesView: ProfilesSurface | null = null;
    private roomsView: RoomsSurface | null = null;
    private sessionsView: SessionsSurface | null = null;
    private composerView: ComposerSurface | null = null;
    private settingsView: SettingsSurface | null = null;

    constructor(appRoot: HTMLElement) {
        this.appRoot = appRoot;
    }

    async init(): Promise<void> {
        this.renderShell();
        this.surfaceRoot = this.appRoot.querySelector("#surface-mount");
        this.toastRoot = this.appRoot.querySelector("#toast-mount");

        this.profilesView = new ProfilesSurface(this.surfaceRoot!);
        this.roomsView = new RoomsSurface(this.surfaceRoot!);
        this.sessionsView = new SessionsSurface(this.surfaceRoot!);
        this.composerView = new ComposerSurface(this.surfaceRoot!);
        this.settingsView = new SettingsSurface(this.surfaceRoot!);

        await this.settingsView.loadConfig(this.showToast.bind(this));
        await this.refreshState();

        this.pollTimer = setInterval(() => {
            void this.refreshState(true);
        }, 2500);

        this.renderActiveSurface();
    }

    private renderShell(): void {
        const surfaces: { id: SurfaceId; label: string }[] = [
            { id: "sessions", label: "Sessions" },
            { id: "profiles", label: "Profiles" },
            { id: "rooms", label: "Rooms" },
            { id: "composer", label: "Composer" },
            { id: "settings", label: "Settings" },
        ];

        this.appRoot.innerHTML = `
            <div class="autonom-app-shell">
                <!-- Top Navigation Bar -->
                <header class="autonom-app-header">
                    <div class="header-left">
                        <div class="brand-group">
                            <span class="brand-badge">${icon("terminal")}</span>
                            <h1 class="brand-title">Autonom Command Center</h1>
                        </div>
                    </div>

                    <!-- Pinned Native Switch Pattern -->
                    <div class="header-center">
                        <div class="agent-editor-switch" role="group" aria-label="Command Center surfaces">
                            <div class="switch-container">
                                ${surfaces.map((s) => `
                                    <button type="button" class="switch-segment ${s.id === this.activeSurface ? "active" : ""}" data-surface="${s.id}" aria-label="${s.label}">
                                        <span class="segment-label">${s.label}</span>
                                    </button>
                                `).join("")}
                            </div>
                        </div>
                    </div>

                    <div class="header-right">
                        <div class="header-status-pill">
                            <span class="dot online running"></span>
                            <span class="status-label">Daemon Active</span>
                            <span class="badge" id="header-unread-badge" title="Human Unread Events">0</span>
                        </div>
                        <button class="icon-button" id="btn-global-refresh" title="Refresh state" type="button">
                            ${icon("arrow-repeat")}
                        </button>
                    </div>
                </header>

                <!-- Active Surface Mount -->
                <main class="autonom-app-main" id="surface-mount"></main>

                <!-- Toast Notifications Mount -->
                <div class="toast-container" id="toast-mount"></div>
            </div>
        `;

        // Wire Segmented Switch
        for (const button of this.appRoot.querySelectorAll<HTMLButtonElement>(".switch-segment")) {
            button.addEventListener("click", () => {
                const target = button.dataset.surface as SurfaceId;
                if (target && target !== this.activeSurface) {
                    this.switchSurface(target);
                }
            });
        }

        // Wire Global Refresh
        const refreshBtn = this.appRoot.querySelector("#btn-global-refresh");
        if (refreshBtn) {
            refreshBtn.addEventListener("click", () => void this.refreshState());
        }
    }

    private switchSurface(surface: SurfaceId): void {
        this.activeSurface = surface;

        // Update switch UI
        for (const button of this.appRoot.querySelectorAll<HTMLButtonElement>(".switch-segment")) {
            const isActive = button.dataset.surface === surface;
            button.classList.toggle("active", isActive);
            button.setAttribute("aria-pressed", String(isActive));
        }

        this.renderActiveSurface();
    }

    private renderActiveSurface(): void {
        if (!this.surfaceRoot) return;

        switch (this.activeSurface) {
            case "profiles":
                this.profilesView?.render(
                    this.daemonState,
                    () => void this.refreshState(),
                    this.showToast.bind(this),
                );
                break;
            case "rooms":
                this.roomsView?.render(
                    this.daemonState,
                    () => void this.refreshState(),
                    this.showToast.bind(this),
                );
                break;
            case "sessions":
                this.sessionsView?.render(
                    this.daemonState,
                    () => void this.refreshState(),
                    this.showToast.bind(this),
                    () => this.switchSurface("composer"),
                );
                break;
            case "composer":
                this.composerView?.render(
                    this.daemonState,
                    this.models,
                    this.workspacePath,
                    () => void this.refreshState(),
                    this.showToast.bind(this),
                    () => this.switchSurface("sessions"),
                );
                break;
            case "settings":
                this.settingsView?.render(
                    this.daemonState,
                    this.providerMode,
                    () => void this.refreshState(),
                    this.showToast.bind(this),
                    (mode) => void this.handleProviderToggle(mode),
                );
                break;
        }
    }

    private async refreshState(silent = false): Promise<void> {
        try {
            const state = await bridge.request<DaemonState>("getState");
            if (state) {
                this.daemonState = state;
            }

            if (!this.models.length) {
                const models = await bridge.request<Model[]>("getModels");
                if (Array.isArray(models)) {
                    this.models = models;
                }
            }

            // Update unread badge in header
            const badge = this.appRoot.querySelector("#header-unread-badge");
            if (badge) {
                const unreadCount = this.daemonState.humanEvents || 0;
                badge.textContent = String(unreadCount);
                badge.classList.toggle("unread-badge", unreadCount > 0);
            }

            const isEditing = this.appRoot.ownerDocument?.activeElement?.tagName === "INPUT"
                || this.appRoot.ownerDocument?.activeElement?.tagName === "TEXTAREA";
            if (!silent || !isEditing) {
                this.renderActiveSurface();
            }
        } catch (err: any) {
            if (!silent) {
                this.showToast(err?.message || "Failed to reach Autonom daemon", true);
            }
        }
    }

    private async handleProviderToggle(nextMode: "autonom" | "devin-cloud"): Promise<void> {
        try {
            await bridge.request("setMode", { mode: nextMode });
            this.providerMode = nextMode;
            this.showToast(`Switched provider to ${nextMode}`);
            this.renderActiveSurface();
        } catch (err: any) {
            this.showToast(err?.message || "Failed to switch provider", true);
        }
    }

    showToast(message: string, isError = false): void {
        if (!this.toastRoot) return;
        const toast = document.createElement("div");
        toast.className = `toast ${isError ? "toast-error" : "toast-success"}`;
        toast.innerHTML = `
            <span class="toast-icon">${icon(isError ? "x" : "check")}</span>
            <span class="toast-message">${escape(message)}</span>
        `;
        this.toastRoot.appendChild(toast);

        setTimeout(() => {
            toast.classList.add("fade-out");
            setTimeout(() => toast.remove(), 300);
        }, 3500);
    }

    dispose(): void {
        if (this.pollTimer) {
            clearInterval(this.pollTimer);
            this.pollTimer = null;
        }
    }
}
