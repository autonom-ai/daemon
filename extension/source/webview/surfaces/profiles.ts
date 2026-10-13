import { avatar, escape, icon, statusLabel } from "../dom";
import type { DaemonState } from "../../protocol";
import { bridge } from "../bridge";

export class ProfilesSurface {
    private container: HTMLElement;
    private creating = false;

    constructor(container: HTMLElement) {
        this.container = container;
    }

    render(state: DaemonState, onRefresh: () => void, showToast: (msg: string, isErr?: boolean) => void): void {
        const profiles = state.profiles || [];
        const rooms = state.rooms || [];

        const getRoomsForProfile = (name: string): string[] => {
            const list: string[] = [];
            for (const room of rooms) {
                const involved = room.membership?.involved;
                if (!involved || involved.includes(name) || room.membership?.owner === name || (room.membership?.admins || []).includes(name)) {
                    list.push(room.name);
                }
            }
            return list;
        };

        const html = `
            <div class="surface-container profiles-surface" data-surface="profiles">
                <div class="surface-header">
                    <div class="surface-title-group">
                        <span class="surface-icon">${icon("people")}</span>
                        <h2>Profiles</h2>
                        <span class="badge">${profiles.length}</span>
                    </div>
                    <button class="primary" id="btn-toggle-create-profile" type="button">
                        ${icon("plus")}
                        <span>New Profile</span>
                    </button>
                </div>

                <div class="create-profile-card ${this.creating ? "" : "hidden"}" id="create-profile-form">
                    <h3>Create Agent Profile</h3>
                    <div class="form-row">
                        <input type="text" id="input-profile-name" placeholder="Profile name (e.g. researcher, reviewer, coder)" maxlength="32" autocomplete="off" />
                        <button class="primary" id="btn-submit-create-profile" type="button">Create</button>
                        <button class="secondary" id="btn-cancel-create-profile" type="button">Cancel</button>
                    </div>
                </div>

                <div class="profiles-grid">
                    ${profiles.length === 0 ? `
                        <div class="empty-state">
                            <span class="empty-icon">${icon("person")}</span>
                            <p>No agent profiles registered yet.</p>
                        </div>
                    ` : profiles.map((p) => {
                        const boundSession = p.session;
                        const boundId = boundSession ? boundSession.id : null;
                        const status = boundSession ? (boundSession.status || "offline") : "offline";
                        const isRunning = status === "online" || status === "starting";
                        const isLoaded = status === "loaded";
                        const dotClass = isRunning ? "online running" : isLoaded ? "loaded" : "offline";
                        const assignedRooms = getRoomsForProfile(p.name);
                        const isHuman = p.name.toLowerCase() === "human";

                        return `
                            <div class="profile-card" data-profile="${escape(p.name)}">
                                <div class="profile-card-header">
                                    <div class="profile-avatar-row">
                                        ${avatar(p.name, "large")}
                                        <div class="profile-identity">
                                            <div class="profile-name-row">
                                                <strong class="profile-name">${escape(p.name)}</strong>
                                                ${isHuman ? `<span class="badge human-badge">Admin</span>` : ""}
                                            </div>
                                            <div class="status-indicator">
                                                <span class="dot ${dotClass}"></span>
                                                <span class="status-text">${escape(statusLabel(status))}</span>
                                            </div>
                                        </div>
                                    </div>
                                    ${!isHuman ? `
                                        <button class="danger-button small btn-remove-profile" data-profile="${escape(p.name)}" title="Remove profile" type="button">
                                            ${icon("trash")}
                                        </button>
                                    ` : ""}
                                </div>

                                <div class="profile-card-body">
                                    <div class="metric-row">
                                        <span class="metric-label">Bound Session</span>
                                        <span class="metric-value">
                                            ${boundId ? `<code class="session-pill">${escape(boundId)}</code>` : `<span class="muted">None</span>`}
                                        </span>
                                    </div>
                                    <div class="metric-row">
                                        <span class="metric-label">Unread Events</span>
                                        <span class="badge ${p.unread > 0 ? "unread-badge" : ""}">${p.unread || 0}</span>
                                    </div>
                                    <div class="metric-row">
                                        <span class="metric-label">Schedules</span>
                                        <span class="badge">${p.schedules || 0}</span>
                                    </div>
                                    <div class="metric-row rooms-row">
                                        <span class="metric-label">Rooms</span>
                                        <div class="room-chips">
                                            ${assignedRooms.length ? assignedRooms.map((r) => `<span class="room-chip">#${escape(r)}</span>`).join("") : `<span class="muted">None</span>`}
                                        </div>
                                    </div>
                                </div>
                            </div>
                        `;
                    }).join("")}
                </div>
            </div>
        `;

        this.container.innerHTML = html;

        // Wire up event listeners
        const toggleBtn = this.container.querySelector("#btn-toggle-create-profile");
        const form = this.container.querySelector("#create-profile-form") as HTMLElement;
        const nameInput = this.container.querySelector("#input-profile-name") as HTMLInputElement;
        const submitBtn = this.container.querySelector("#btn-submit-create-profile");
        const cancelBtn = this.container.querySelector("#btn-cancel-create-profile");

        if (toggleBtn) {
            toggleBtn.addEventListener("click", () => {
                this.creating = !this.creating;
                if (form) form.classList.toggle("hidden", !this.creating);
                if (this.creating && nameInput) nameInput.focus();
            });
        }

        if (cancelBtn) {
            cancelBtn.addEventListener("click", () => {
                this.creating = false;
                if (form) form.classList.add("hidden");
                if (nameInput) nameInput.value = "";
            });
        }

        const handleCreate = async () => {
            if (!nameInput) return;
            const name = nameInput.value.trim().toLowerCase();
            if (!name) {
                showToast("Please enter a profile name", true);
                return;
            }
            if (!/^[a-z0-9_-]{1,32}$/.test(name)) {
                showToast("Profile name must be 1-32 alphanumeric characters", true);
                return;
            }
            try {
                await bridge.request("createProfile", { name });
                showToast(`Profile "${name}" created successfully`);
                this.creating = false;
                nameInput.value = "";
                onRefresh();
            } catch (err: any) {
                showToast(err?.message || "Failed to create profile", true);
            }
        };

        if (submitBtn) {
            submitBtn.addEventListener("click", () => void handleCreate());
        }
        if (nameInput) {
            nameInput.addEventListener("keydown", (e) => {
                if (e.key === "Enter") void handleCreate();
            });
        }

        for (const btn of this.container.querySelectorAll<HTMLButtonElement>(".btn-remove-profile")) {
            btn.addEventListener("click", async () => {
                const targetName = btn.dataset.profile;
                if (!targetName) return;
                try {
                    await bridge.request("removeProfile", { name: targetName });
                    showToast(`Profile "${targetName}" removed`);
                    onRefresh();
                } catch (err: any) {
                    showToast(err?.message || "Failed to remove profile", true);
                }
            });
        }
    }
}
