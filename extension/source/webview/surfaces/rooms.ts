import { escape, icon } from "../dom";
import { renderEntries } from "../messages";
import type { DaemonState, Entry } from "../../protocol";
import { bridge } from "../bridge";

export class RoomsSurface {
    private container: HTMLElement;
    private selectedRoom: string | null = null;
    private messages: Entry[] = [];
    private loadingMessages = false;

    constructor(container: HTMLElement) {
        this.container = container;
    }

    render(state: DaemonState, onRefresh: () => void, showToast: (msg: string, isErr?: boolean) => void): void {
        const rooms = state.rooms || [];
        if (!this.selectedRoom && rooms.length > 0) {
            this.selectedRoom = rooms[0]!.name;
            void this.loadRoomMessages(this.selectedRoom, onRefresh);
        }

        const active = rooms.find((r) => r.name === this.selectedRoom) || rooms[0] || null;

        const html = `
            <div class="surface-container rooms-surface" data-surface="rooms">
                <div class="rooms-layout">
                    <!-- Left Sidebar: Room List -->
                    <div class="rooms-sidebar">
                        <div class="rooms-sidebar-header">
                            <div class="surface-title-group">
                                <span class="surface-icon">${icon("chat-dots")}</span>
                                <h2>Rooms</h2>
                                <span class="badge">${rooms.length}</span>
                            </div>
                        </div>

                        <div class="rooms-list">
                            ${rooms.length === 0 ? `
                                <div class="empty-state small">
                                    <p>No active rooms</p>
                                </div>
                            ` : rooms.map((r) => {
                                const isSelected = r.name === this.selectedRoom;
                                const unread = r.unread || 0;
                                return `
                                    <button class="room-nav-item ${isSelected ? "active" : ""}" data-room="${escape(r.name)}" type="button">
                                        <div class="room-nav-left">
                                            <span class="room-hash">#</span>
                                            <span class="room-name">${escape(r.name)}</span>
                                        </div>
                                        <div class="room-nav-right">
                                            ${unread > 0 ? `<span class="badge unread-badge room-unread-badge" data-unread="${unread}">${unread}</span>` : ""}
                                            <span class="room-msg-count muted">${r.count || 0}</span>
                                        </div>
                                    </button>
                                `;
                            }).join("")}
                        </div>
                    </div>

                    <!-- Right Main: Active Room Transcript and Composer -->
                    <div class="room-chat-pane">
                        ${active ? `
                            <div class="room-chat-header">
                                <div class="room-header-info">
                                    <div class="room-header-title-row">
                                        <span class="room-hash-large">#</span>
                                        <h3 class="room-chat-title">${escape(active.name)}</h3>
                                        <span class="badge">${active.count || 0} messages</span>
                                    </div>
                                    <div class="room-header-meta">
                                        <span>Owner: <strong>${escape(active.membership?.owner || "none")}</strong></span>
                                        ${active.membership?.involved ? `<span>· Members: ${escape(active.membership.involved.join(", "))}</span>` : ""}
                                    </div>
                                </div>
                                <button class="secondary icon-button" id="btn-refresh-room" title="Refresh messages" type="button">
                                    ${icon("arrow-repeat")}
                                </button>
                            </div>

                            <div class="room-messages-container" id="room-messages-scroll">
                                ${this.loadingMessages ? `
                                    <div class="loading-state">
                                        <span>Loading messages...</span>
                                    </div>
                                ` : renderEntries(this.messages)}
                            </div>

                            <div class="room-composer-box">
                                <div class="composer-target-info">
                                    <span>Posting as <strong>human operator</strong> to <strong>#${escape(active.name)}</strong></span>
                                </div>
                                <div class="composer-input-row">
                                    <textarea id="room-message-input" placeholder="Message #${escape(active.name)}... (Enter to send, Shift+Enter for newline)" rows="2"></textarea>
                                    <button class="primary" id="btn-send-room-message" type="button">
                                        ${icon("send")}
                                        <span>Send</span>
                                    </button>
                                </div>
                                <div class="composer-pings-row">
                                    <span class="pings-label">Ping profiles:</span>
                                    <div class="pings-chips" id="pings-container">
                                        ${(state.profiles || []).filter((p) => p.name.toLowerCase() !== "human").map((p) => `
                                            <label class="ping-chip-label">
                                                <input type="checkbox" class="ping-checkbox" value="${escape(p.name)}" />
                                                <span>@${escape(p.name)}</span>
                                            </label>
                                        `).join("")}
                                    </div>
                                </div>
                            </div>
                        ` : `
                            <div class="empty-state">
                                <span class="empty-icon">${icon("chat")}</span>
                                <p>Select a room to view transcript and messages</p>
                            </div>
                        `}
                    </div>
                </div>
            </div>
        `;

        this.container.innerHTML = html;

        // Wire up room selection
        for (const item of this.container.querySelectorAll<HTMLButtonElement>(".room-nav-item")) {
            item.addEventListener("click", () => {
                const roomName = item.dataset.room;
                if (roomName && roomName !== this.selectedRoom) {
                    this.selectedRoom = roomName;
                    void this.loadRoomMessages(roomName, onRefresh);
                }
            });
        }

        // Wire refresh
        const refreshBtn = this.container.querySelector("#btn-refresh-room");
        if (refreshBtn && this.selectedRoom) {
            refreshBtn.addEventListener("click", () => {
                void this.loadRoomMessages(this.selectedRoom!, onRefresh);
            });
        }

        // Wire send message
        const sendBtn = this.container.querySelector("#btn-send-room-message");
        const textarea = this.container.querySelector("#room-message-input") as HTMLTextAreaElement;

        const handleSend = async () => {
            if (!this.selectedRoom || !textarea) return;
            const text = textarea.value.trim();
            if (!text) return;

            // Collect checked pings
            const pings: string[] = [];
            for (const cb of this.container.querySelectorAll<HTMLInputElement>(".ping-checkbox:checked")) {
                pings.push(cb.value);
            }

            try {
                await bridge.request("postMessage", {
                    room: this.selectedRoom,
                    target: this.selectedRoom,
                    text,
                    ping: pings,
                    pings,
                });
                textarea.value = "";
                showToast(`Message posted to #${this.selectedRoom}`);
                await this.loadRoomMessages(this.selectedRoom, onRefresh);
            } catch (err: any) {
                showToast(err?.message || "Failed to post message", true);
            }
        };

        if (sendBtn) {
            sendBtn.addEventListener("click", () => void handleSend());
        }
        if (textarea) {
            textarea.addEventListener("keydown", (e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                    e.preventDefault();
                    void handleSend();
                }
            });
        }

        // Auto-scroll messages to bottom
        const scrollEl = this.container.querySelector("#room-messages-scroll");
        if (scrollEl) {
            scrollEl.scrollTop = scrollEl.scrollHeight;
        }
    }

    private async loadRoomMessages(roomName: string, onRefresh: () => void): Promise<void> {
        this.loadingMessages = true;
        try {
            const entries = await bridge.request<Entry[]>("getMessages", {
                source: "room",
                target: roomName,
            });
            this.messages = Array.isArray(entries) ? entries : [];
            // Refresh parent state to update unread badge in state/sidebar
            onRefresh();
        } catch {
            this.messages = [];
        } finally {
            this.loadingMessages = false;
        }
    }
}
