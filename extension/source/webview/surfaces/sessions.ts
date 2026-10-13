import { escape, icon, relativeTime } from "../dom";
import { renderConversation } from "../messages";
import type { DaemonState, Execution, Session, Transcript } from "../../protocol";
import { bridge } from "../bridge";

export class SessionsSurface {
    private container: HTMLElement;
    private transcriptModalData: { session: Session | null; transcript: Transcript | null } | null = null;
    private resumingSessionId: string | null = null;

    constructor(container: HTMLElement) {
        this.container = container;
    }

    render(
        state: DaemonState,
        onRefresh: () => void,
        showToast: (msg: string, isErr?: boolean) => void,
        onOpenComposer: () => void,
    ): void {
        const sessions = state.sessions || [];
        const runs = state.runs || [];

        const html = `
            <div class="surface-container sessions-surface" data-surface="sessions">
                <div class="surface-header">
                    <div class="surface-title-group">
                        <span class="surface-icon">${icon("terminal")}</span>
                        <h2>Sessions & Runs</h2>
                        <span class="badge">${sessions.length} managed</span>
                    </div>
                    <button class="primary" id="btn-go-to-composer" type="button">
                        ${icon("plus")}
                        <span>New Session</span>
                    </button>
                </div>

                <!-- Resume Prompt Drawer/Modal -->
                ${this.resumingSessionId ? `
                    <div class="inline-action-card resume-card">
                        <h3>Resume Session: <code>${escape(this.resumingSessionId)}</code></h3>
                        <div class="form-group">
                            <textarea id="input-resume-prompt" placeholder="Provide instructions or follow-up for this session..." rows="3"></textarea>
                        </div>
                        <div class="button-row">
                            <button class="primary" id="btn-submit-resume" type="button">Resume</button>
                            <button class="secondary" id="btn-cancel-resume" type="button">Cancel</button>
                        </div>
                    </div>
                ` : ""}

                <!-- Transcript Viewer Modal -->
                ${this.transcriptModalData ? `
                    <div class="modal-backdrop" id="transcript-modal">
                        <div class="modal-dialog">
                            <div class="modal-header">
                                <div class="modal-title-group">
                                    <h3>Transcript: ${escape(this.transcriptModalData.session?.title || this.transcriptModalData.session?.id || "Session")}</h3>
                                    <span class="badge">${this.transcriptModalData.transcript?.messages?.length || 0} messages</span>
                                </div>
                                <button class="icon-button" id="btn-close-transcript" type="button">${icon("x")}</button>
                            </div>
                            <div class="modal-body transcript-messages-scroll">
                                ${this.transcriptModalData.transcript ? renderConversation(this.transcriptModalData.transcript.messages || []) : "<p>No messages recorded.</p>"}
                            </div>
                        </div>
                    </div>
                ` : ""}

                <!-- Managed Sessions List -->
                <div class="section-title-row">
                    <h3>Managed Sessions</h3>
                </div>

                <div class="sessions-list">
                    ${sessions.length === 0 ? `
                        <div class="empty-state">
                            <span class="empty-icon">${icon("terminal")}</span>
                            <p>No managed sessions found. Click "New Session" to start one.</p>
                        </div>
                    ` : sessions.map((s) => {
                        const isRunning = s.status === "online" || s.status === "starting";
                        const isFailed = s.status === "failed";
                        const dotClass = isRunning ? "online running" : isFailed ? "failed" : "offline";

                        return `
                            <div class="session-card" data-session="${escape(s.id)}">
                                <div class="session-card-header">
                                    <div class="session-title-col">
                                        <div class="session-id-row">
                                            <span class="dot ${dotClass}"></span>
                                            <strong class="session-title">${escape(s.title || s.id)}</strong>
                                            <code class="session-id-code">${escape(s.id)}</code>
                                        </div>
                                        <div class="session-meta-row">
                                            <span>Model: <strong>${escape(s.model || "swe-2-medium")}</strong></span>
                                            <span>· Mode: <strong>${escape(s.mode || "bypass")}</strong></span>
                                            ${s.profile ? `<span>· Profile: <strong>@${escape(s.profile)}</strong></span>` : ""}
                                            ${s.lastActivityAt ? `<span>· Active ${escape(relativeTime(s.lastActivityAt))}</span>` : ""}
                                        </div>
                                    </div>
                                    <div class="session-actions-col">
                                        <button class="secondary small btn-view-transcript" data-id="${escape(s.id)}" type="button" title="View Transcript">
                                            ${icon("file-earmark-text")}
                                            <span>Transcript</span>
                                        </button>
                                        <button class="secondary small btn-resume-session" data-id="${escape(s.id)}" type="button" title="Resume Session">
                                            ${icon("play")}
                                            <span>Resume</span>
                                        </button>
                                        ${isRunning && s.executionId ? `
                                            <button class="secondary small danger-hover btn-stop-session" data-exec="${escape(s.executionId)}" type="button" title="Stop Session">
                                                ${icon("stop")}
                                                <span>Stop</span>
                                            </button>
                                        ` : ""}
                                        <button class="danger-button small btn-remove-session" data-id="${escape(s.id)}" type="button" title="Remove Session">
                                            ${icon("trash")}
                                            <span>Remove</span>
                                        </button>
                                    </div>
                                </div>
                                <div class="session-card-footer">
                                    <span class="directory-path muted">${escape(s.directory || "Workspace")}</span>
                                </div>
                            </div>
                        `;
                    }).join("")}
                </div>

                <!-- Recent Executions / Runs -->
                <div class="section-title-row runs-header">
                    <h3>Recent Executions (${runs.length})</h3>
                </div>

                <div class="runs-table-container">
                    <table class="runs-table">
                        <thead>
                            <tr>
                                <th>Kind</th>
                                <th>Session</th>
                                <th>Status</th>
                                <th>Model</th>
                                <th>Created</th>
                                <th>Finished</th>
                            </tr>
                        </thead>
                        <tbody>
                            ${runs.length === 0 ? `
                                <tr><td colspan="6" class="text-center muted">No execution runs recorded</td></tr>
                            ` : runs.slice(-20).reverse().map((r) => {
                                const isSuccess = r.status === "succeeded";
                                const isRunning = r.status === "running";
                                const isFailed = r.status === "failed" || r.status === "interrupted";
                                const badgeClass = isSuccess ? "badge-success" : isRunning ? "badge-running" : isFailed ? "badge-danger" : "";

                                return `
                                    <tr>
                                        <td><span class="kind-tag">${escape(r.kind)}</span></td>
                                        <td><code>${escape(r.sessionId || "—")}</code></td>
                                        <td><span class="badge ${badgeClass}">${escape(r.status)}</span></td>
                                        <td><span class="muted">${escape(r.model || "—")}</span></td>
                                        <td><span class="muted">${escape(relativeTime(r.createdAt))}</span></td>
                                        <td><span class="muted">${r.finishedAt ? escape(relativeTime(r.finishedAt)) : "In progress"}</span></td>
                                    </tr>
                                `;
                            }).join("")}
                        </tbody>
                    </table>
                </div>
            </div>
        `;

        this.container.innerHTML = html;

        // Wire "New Session"
        const newSessionBtn = this.container.querySelector("#btn-go-to-composer");
        if (newSessionBtn) {
            newSessionBtn.addEventListener("click", () => onOpenComposer());
        }

        // Wire Resume flow
        for (const btn of this.container.querySelectorAll<HTMLButtonElement>(".btn-resume-session")) {
            btn.addEventListener("click", () => {
                this.resumingSessionId = btn.dataset.id || null;
                onRefresh();
            });
        }

        const cancelResumeBtn = this.container.querySelector("#btn-cancel-resume");
        if (cancelResumeBtn) {
            cancelResumeBtn.addEventListener("click", () => {
                this.resumingSessionId = null;
                onRefresh();
            });
        }

        const submitResumeBtn = this.container.querySelector("#btn-submit-resume");
        const promptInput = this.container.querySelector("#input-resume-prompt") as HTMLTextAreaElement;
        if (submitResumeBtn && promptInput && this.resumingSessionId) {
            submitResumeBtn.addEventListener("click", async () => {
                const prompt = promptInput.value.trim();
                if (!prompt) {
                    showToast("Please enter a resume prompt", true);
                    return;
                }
                const targetId = this.resumingSessionId!;
                try {
                    await bridge.request("resumeSession", { id: targetId, prompt });
                    showToast(`Resume execution started for ${targetId}`);
                    this.resumingSessionId = null;
                    onRefresh();
                } catch (err: any) {
                    showToast(err?.message || "Failed to resume session", true);
                }
            });
        }

        // Wire Stop flow
        for (const btn of this.container.querySelectorAll<HTMLButtonElement>(".btn-stop-session")) {
            btn.addEventListener("click", async () => {
                const execId = btn.dataset.exec;
                if (!execId) return;
                try {
                    await bridge.request("stopExecution", { id: execId });
                    showToast(`Stopped execution ${execId}`);
                    onRefresh();
                } catch (err: any) {
                    showToast(err?.message || "Failed to stop execution", true);
                }
            });
        }

        // Wire Remove flow with async execution polling
        for (const btn of this.container.querySelectorAll<HTMLButtonElement>(".btn-remove-session")) {
            btn.addEventListener("click", async () => {
                const targetId = btn.dataset.id;
                if (!targetId) return;
                try {
                    btn.disabled = true;
                    btn.innerHTML = `<span>Removing...</span>`;
                    const exec = await bridge.request<Execution>("removeSession", { id: targetId });
                    showToast(`Removal started for ${targetId}...`);

                    // Poll execution until finished
                    if (exec?.id) {
                        let attempts = 0;
                        const poll = setInterval(async () => {
                            attempts++;
                            try {
                                const current = await bridge.request<Execution>("getExecution", { id: exec.id });
                                if (current.status !== "running" || attempts > 20) {
                                    clearInterval(poll);
                                    if (current.status === "succeeded") {
                                        showToast(`Session ${targetId} removed successfully`);
                                    } else {
                                        showToast(`Session removal finished with status: ${current.status}`, current.status !== "succeeded");
                                    }
                                    onRefresh();
                                }
                            } catch {
                                clearInterval(poll);
                                onRefresh();
                            }
                        }, 1000);
                    } else {
                        onRefresh();
                    }
                } catch (err: any) {
                    showToast(err?.message || "Failed to remove session", true);
                    onRefresh();
                }
            });
        }

        // Wire View Transcript modal
        for (const btn of this.container.querySelectorAll<HTMLButtonElement>(".btn-view-transcript")) {
            btn.addEventListener("click", async () => {
                const targetId = btn.dataset.id;
                if (!targetId) return;
                const session = sessions.find((s) => s.id === targetId) || null;
                try {
                    const transcript = await bridge.request<Transcript>("getTranscript", { id: targetId });
                    this.transcriptModalData = { session, transcript };
                    onRefresh();
                } catch (err: any) {
                    showToast(err?.message || "Could not load transcript", true);
                }
            });
        }

        const closeTranscriptBtn = this.container.querySelector("#btn-close-transcript");
        if (closeTranscriptBtn) {
            closeTranscriptBtn.addEventListener("click", () => {
                this.transcriptModalData = null;
                onRefresh();
            });
        }
    }
}
