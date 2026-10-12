import { bridge, field, toast } from "./bridge";
import { safeGetStorage, safeSetStorage } from "./storage";
import { avatar, escape, icon, iconButton, identicon, modeOptions, modelOptions, relativeTime, statusLabel } from "./dom";
import { emptyConversation, renderConversation, renderEntries } from "./messages";
import { Sidebar } from "./sidebar";
import { SettingsView } from "./settings";
import { ComposerView } from "./composer";
import { destination, record } from "../protocol";
import type { Destination, Event, Execution, HostMessage, PermissionMode, Profile, Schedule, Transcript, ViewState } from "../protocol";

export function brandSvg(size = 16): string
{
    return `<svg class="icon brand-icon" width="${size}" height="${size}" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" d="M6 3.5A1.5 1.5 0 0 1 7.5 2h1A1.5 1.5 0 0 1 10 3.5v1A1.5 1.5 0 0 1 8.5 6v1H14a.5.5 0 0 1 .5.45V9a2.5 2.5 0 0 1-2.5 2.5H11v1.5a1.5 1.5 0 0 1-1.5 1.5h-1a1.5 1.5 0 0 1-1.5-1.5v-1a1.5 1.5 0 0 1 1.5-1.5H9V10a1.5 1.5 0 0 0 1.5-1.5V7.5H8.5A1.5 1.5 0 0 1 7 6V4.5H5.5A1.5 1.5 0 0 0 4 6v1.5h.5A1.5 1.5 0 0 1 6 9v1a1.5 1.5 0 0 1-1.5 1.5h-1A1.5 1.5 0 0 1 2 11V9.5A1.5 1.5 0 0 1 3.5 8H4V6a2.5 2.5 0 0 1 2.5-2.5H7v-1A1.5 1.5 0 0 1 6 3.5v-1a1.5 1.5 0 0 1 1.5-1.5h1A1.5 1.5 0 0 1 10 2.5v1z"/></svg>`;
}

const app = document.getElementById("app") as HTMLElement;
const modalRoot = document.getElementById("modal-root") as HTMLElement;
const isSidebar = document.body.dataset.view === "sidebar";
const sidebar = isSidebar ? new Sidebar(app) : undefined;
let settingsView: SettingsView | undefined;
let composerView: ComposerView | undefined;
let viewMode: "conversation" | "settings" = "conversation";
let provider = safeGetStorage("autonom.provider", "autonom");
let state: ViewState | undefined;
let selected = destination(record(bridge.getState())?.destination);
let transcript: Transcript | null = null;
let conversationSignature = "";
let selectedProfile = "";
let schedules: Schedule[] = [];
let modelSignature = "";
let navigationSignature = "";
let inspectorSignature = "";
let submitting = false;

function renderCloudSpaces(workspaceName?: string): string
{
    const name = workspaceName || "Default Workspace";
    return `
        <div class="cloud-spaces-container">
            <div class="cloud-spaces-header">
                <span class="eyebrow">${icon("cloud")}Cloud Spaces</span>
                <span class="badge cloud-badge">Connected</span>
            </div>
            <div class="cloud-spaces-list">
                <div class="cloud-space-item active">
                    <span class="cloud-space-icon">${icon("folder2-open")}</span>
                    <div class="cloud-space-info">
                        <strong>${escape(name)}</strong>
                        <span class="cloud-space-meta">Primary Cloud Environment</span>
                    </div>
                    <span class="dot online running" title="Cloud environment active"></span>
                </div>
                <div class="cloud-space-item">
                    <span class="cloud-space-icon">${icon("hdd-network")}</span>
                    <div class="cloud-space-info">
                        <strong>Shared Team Space</strong>
                        <span class="cloud-space-meta">Remote Sandbox · us-west</span>
                    </div>
                </div>
            </div>
            <div class="cloud-spaces-notice">
                <span class="cloud-notice-icon">${icon("cloud-check")}</span>
                <div>
                    <strong>Devin Cloud Mode</strong>
                    <p>Tasks run on remote Cognition infrastructure. Toggle Autonom above to return to local daemon agents.</p>
                </div>
            </div>
        </div>
    `;
}

function setProvider(next: string): void
{
    provider = next === "devin-cloud" ? "devin-cloud" : "autonom";
    safeSetStorage("autonom.provider", provider);
    const isAutonom = provider === "autonom";
    const nav = document.querySelector<HTMLElement>(".navigation");
    const cloud = document.getElementById("cloud-spaces-placeholder");

    const autonomSegments = document.querySelectorAll<HTMLElement>("[data-provider='autonom']");
    const cloudSegments = document.querySelectorAll<HTMLElement>("[data-provider='devin-cloud']");
    autonomSegments.forEach((el) => {
        el.classList.toggle("active", isAutonom);
        el.setAttribute("data-active", String(isAutonom));
    });
    cloudSegments.forEach((el) => {
        el.classList.toggle("active", !isAutonom);
        el.setAttribute("data-active", String(!isAutonom));
    });

    if (nav !== null)
    {
        nav.hidden = !isAutonom;
    }
    if (cloud !== null)
    {
        cloud.hidden = isAutonom;
    }
    const autonomTiers = document.querySelectorAll<HTMLElement>("[data-autonom-tier]");
    autonomTiers.forEach((el) => { el.hidden = !isAutonom; });
    const cloudGroups = document.querySelectorAll<HTMLElement>("[data-slot='sidebar-group']:not([data-autonom-tier]), .command-center-cloud");
    cloudGroups.forEach((el) => { el.hidden = isAutonom; });
}

function switchViewMode(mode: "conversation" | "settings"): void
{
    if (viewMode === mode && mode === "conversation")
        return;
    viewMode = mode;
    const messages = document.getElementById("messages");
    const composer = document.getElementById("composer");
    const settingsPane = document.getElementById("settings-view");

    if (mode === "settings")
    {
        messages?.setAttribute("hidden", "true");
        composer?.setAttribute("hidden", "true");
        if (settingsPane !== null)
        {
            settingsPane.removeAttribute("hidden");
            settingsView?.render(state);
        }
        renderHeader();
    }
    else
    {
        messages?.removeAttribute("hidden");
        composer?.removeAttribute("hidden");
        settingsPane?.setAttribute("hidden", "true");
        renderHeader();
        renderComposer();
    }
}

if (!isSidebar)
{
    const isAutonom = provider === "autonom";
    app.innerHTML = `<div class="shell">
        <header class="app-header"><div class="brand">${brandSvg(18)}Autonom</div><span class="workspace-pill" id="workspace-pill">${icon("folder2-open")}Workspace</span>
            <div class="header-end"><span class="status" id="daemon-status"><span class="dot"></span>Connecting</span><button class="primary header-new-session" type="button" data-action="headerNewSession">${icon("plus-lg")}New session</button>${iconButton("settings", "gear", "Control center")}</div></header>
        <div id="connection-banner" class="connection-banner" hidden></div>
        <main class="layout">
            <aside class="sidebar-rail">
                <div class="sidebar-rail-top">
                    <ul data-slot="sidebar-menu" class="provider-toggle-rail-menu">
                        <li data-slot="sidebar-menu-item" class="provider-toggle-item group/menu-item relative isolate mb-2 mt-1">
                            <div class="switch-container group/switch relative flex w-full p-0.5 rounded-[7px] bg-tint-secondary items-center h-[28px] box-border mb-1" style="background-color: rgb(var(--tint-secondary, 255 255 255 / 0.06)); border: 1px solid rgb(var(--border-secondary, 255 255 255 / 0.08));">
                                <button type="button" data-action="setProvider" data-provider="autonom" data-active="${isAutonom}" class="switch-segment ${isAutonom ? "active" : ""} flex-1 flex items-center justify-center h-[22px] px-2 rounded-[5px] text-12 font-medium cursor-pointer select-none transition-all">Autonom</button>
                                <button type="button" data-action="setProvider" data-provider="devin-cloud" data-active="${!isAutonom}" class="switch-segment ${!isAutonom ? "active" : ""} flex-1 flex items-center justify-center h-[22px] px-2 rounded-[5px] text-12 font-medium cursor-pointer select-none transition-all">Devin Cloud</button>
                            </div>
                        </li>
                    </ul>
                    <button class="primary action-new-session" type="button" data-action="newSession">${icon("plus-lg")}New session</button>
                </div>
                <div id="cloud-spaces-placeholder" class="command-center-cloud" ${isAutonom ? "hidden" : ""}>
                    ${renderCloudSpaces(state?.workspaceName)}
                </div>
                <nav class="navigation" aria-label="Conversations" ${isAutonom ? "" : "hidden"}>
                    <div id="navigation" class="navigation-scroll"></div>
                    <footer class="nav-footer">${avatar("you", "small")}<div><strong>You</strong><br><span class="eyebrow">Human profile</span></div>${iconButton("pings", "bell", "Your pings")}</footer>
                </nav>
            </aside>
            <section class="chat-column">
                <header class="conversation-header" id="conversation-header"></header>
                <div id="settings-view" class="settings-pane" hidden></div>
                <div class="messages" id="messages" role="log" aria-label="Conversation"></div>
                <form id="composer" class="composer"><div class="composer-shell"><textarea id="composer-text" name="text" rows="3" placeholder="Choose a conversation" aria-label="Message" disabled></textarea>
                    <div class="composer-bottom"><span class="composer-hint" id="composer-hint">Enter to send · Shift+Enter for newline</span><button type="submit" class="send-button" id="send-button" aria-label="Send message" disabled>${icon("arrow-up")}</button></div></div><p class="composer-caption" id="composer-caption">Daemon-managed sessions. Your workspace, your tools.</p></form>
            </section>
            <aside class="inspector"><header class="inspector-header"><span class="eyebrow">Profiles</span><span class="badge" id="profile-count">0</span></header><div class="inspector-scroll" id="inspector"></div></aside>
        </main></div>`;
    settingsView = new SettingsView(document.getElementById("settings-view") as HTMLElement, () => switchViewMode("conversation"));
    const composerEl = document.getElementById("composer") as HTMLFormElement | null;
    if (composerEl)
    {
        composerView = new ComposerView(composerEl);
    }
    renderWelcome();
}

window.addEventListener("message", (event: MessageEvent<HostMessage>) =>
{
    const message = event.data;
    if (!record(message) || typeof message.type !== "string")
        return;
    switch (message.type)
    {
        case "state":
            state = message.state;
            if (sidebar !== undefined)
                sidebar.render(state);
            else
            {
                renderState();
                if (viewMode === "settings")
                    settingsView?.render(state);
            }
            break;
        case "selection":
            if (!isSidebar)
                select(message.destination, false);
            break;
        case "conversation":
            if (selected?.id !== message.destination.id || selected.kind !== message.destination.kind || isSidebar)
                return;
            transcript = message.transcript;
            renderHeader();
            renderComposer();
            renderMessages(message);
            break;
        case "schedules":
            if (message.profile === selectedProfile)
            {
                schedules = message.schedules;
                renderScheduleList();
            }
            break;
        case "events":
            if (message.profile === selectedProfile)
                renderEvents(message.events);
            break;
        case "newSession":
            if (!isSidebar)
                newSession();
            break;
        case "result":
            sidebar?.saved(message.action, message.ok);
            settingsView?.saved(message.action, message.ok);
            if (!message.ok)
            {
                toast(message.error, true);
                submitting = false;
                const button = modalRoot.querySelector<HTMLButtonElement>('button[type="submit"]');
                if (button !== null)
                    button.disabled = false;
            }
            else if (["start", "createRoom", "membership", "deleteRoom", "removeSession", "schedule"].includes(message.action))
                closeDialog();
            else if (["post", "resume"].includes(message.action))
            {
                const input = document.getElementById("composer-text") as HTMLTextAreaElement | null;
                if (input !== null)
                    input.value = "";
            }
            if (["deleteRoom", "removeSession"].includes(message.action) && message.ok)
            {
                selected = undefined;
                transcript = null;
                conversationSignature = "";
                bridge.setState({ destination: undefined });
                renderNavigation();
                renderHeader();
                renderComposer();
                renderWelcome();
            }
            if (["start", "post", "resume", "createRoom", "schedule"].includes(message.action))
            {
                submitting = false;
                const button = modalRoot.querySelector<HTMLButtonElement>('button[type="submit"]');
                if (button !== null)
                    button.disabled = false;

                renderComposer();
            }
            break;
    }
});

if (!isSidebar)
{
    document.addEventListener("click", (event) =>
    {
        const target = event.target as Element;
        const anchor = target.closest<HTMLAnchorElement>("a[href]");
        if (anchor !== null)
        {
            event.preventDefault();
            bridge.postMessage({ type: "openLink", href: anchor.href });
            return;
        }
        const button = target.closest<HTMLButtonElement>("[data-action]");
        if (button === null)
            return;
        handleClick(button);
    });
    document.addEventListener("submit", (event) =>
    {
        event.preventDefault();
        const form = event.target as HTMLFormElement;
        submit(form);
    });
    document.addEventListener("change", (event) =>
    {
        const input = event.target as HTMLInputElement;
        if (input.id === "autonom-provider-toggle")
            setProvider(input.checked ? "autonom" : "devin-cloud");
        if (input.name === "scheduleType")
            renderScheduleFields(input.value);
        if (input.name === "restricted")
        {
            const members = document.getElementById("membership-list");
            if (members !== null)
                members.hidden = !input.checked;
        }
    });
    document.addEventListener("keydown", (event) =>
    {
        if (event.key === "Escape")
            closeDialog();
        if (event.key === "Enter" && !event.shiftKey && !event.isComposing
            && (event.target as HTMLElement).id === "composer-text")
        {
            event.preventDefault();
            (document.getElementById("composer") as HTMLFormElement).requestSubmit();
        }
        if (event.key === "Tab" && modalRoot.childElementCount)
        {
            const inputs = modalRoot.querySelectorAll<HTMLElement>('button, input, textarea, select, a[href]');
            const first = inputs[0];
            const last = inputs[inputs.length - 1];
            if (event.shiftKey && document.activeElement === first)
            {
                event.preventDefault();
                last?.focus();
            }
            else if (!event.shiftKey && document.activeElement === last)
            {
                event.preventDefault();
                first?.focus();
            }
        }
    });
}
bridge.postMessage({ type: "ready" });
if (selected !== undefined && !isSidebar)
    bridge.postMessage({ type: "select", destination: selected });

function select(value: Destination, notify = true): void
{
    const switching = selected?.kind !== value.kind || selected?.id !== value.id;
    selected = value;

    if (state !== undefined)
    {
        if (value.kind === "room")
        {
            const room = state.daemon.rooms.find((r) => r.name === value.id);
            if (room && room.unread > 0)
                room.unread = 0;
            const badge = document.querySelector<HTMLElement>(`[data-kind="room"][data-id="${value.id}"] .unread-badge`);
            if (badge)
                badge.remove();
        }
        else if (value.kind === "dm")
        {
            const profile = state.daemon.profiles.find((p) => p.name === value.id);
            if (profile && profile.unread > 0)
                profile.unread = 0;
        }
        else if (value.kind === "pings")
        {
            state.daemon.humanEvents = 0;
        }
    }

    transcript = null;
    conversationSignature = "";
    navigationSignature = "";
    bridge.setState({ destination: value });
    document.body.classList.remove("navigation-open");
    document.body.classList.remove("inspector-open");
    if (viewMode === "settings")
        switchViewMode("conversation");
    const messages = document.getElementById("messages");
    if (messages !== null && switching)
    {
        messages.dataset.permissions = "";
        messages.innerHTML = emptyConversation("Loading conversation…", "");
    }
    renderNavigation();
    renderHeader();
    renderComposer();
    if (notify)
        bridge.postMessage({ type: "select", destination: value });
}

function renderState(): void
{
    if (state === undefined)
        return;
    const pill = document.getElementById("workspace-pill") as HTMLElement;
    pill.innerHTML = `${icon("folder2-open")}${escape(state.workspaceName || "No workspace")}`;
    pill.title = state.workspace;
    const status = document.getElementById("daemon-status") as HTMLElement;
    status.innerHTML = `<span class="dot ${state.connected ? "online running" : "failed offline"}"></span>${state.connected ? "Connected" : "Disconnected"}`;
    const banner = document.getElementById("connection-banner") as HTMLElement;
    banner.hidden = state.connected;
    banner.innerHTML = `${icon("exclamation-circle")}<span>${escape(state.error || "Connecting to Autonom…")}</span>${iconButton("refresh", "arrow-clockwise", "Reconnect")}`;
    const cloud = document.getElementById("cloud-spaces-placeholder");
    if (cloud !== null && state.workspaceName)
    {
        cloud.innerHTML = renderCloudSpaces(state.workspaceName);
    }
    renderNavigation();
    renderInspector();
    renderHeader();
    renderComposer();
    if (selected === undefined && viewMode !== "settings")
        renderWelcome();
    renderPermissionCards();
    if (viewMode === "settings")
        settingsView?.render(state);
}

function getProfileStatus(profile: Profile, runs: Execution[] = state?.daemon.runs ?? []): { className: string; label: string }
{
    const boundSession = profile.session;
    const activeRun = runs.find((r) =>
        (boundSession && r.sessionId === boundSession.id) || (r.profile && r.profile.toLowerCase() === profile.name.toLowerCase()));

    if (activeRun && (activeRun.status === "running" || activeRun.status === "stopping"))
        return { className: "dot online running", label: "Working" };

    if (boundSession)
    {
        if (boundSession.status === "online" || boundSession.status === "starting")
            return { className: "dot online running", label: statusLabel(boundSession.status) };
        if (boundSession.status === "stopping" || boundSession.status === "loaded")
            return { className: "dot online running", label: statusLabel(boundSession.status) };
        if (boundSession.status === "offline")
            return { className: "dot idle", label: "Idle" };
        if (boundSession.status === "failed")
            return { className: "dot failed", label: "Failed" };
    }
    return { className: "dot offline", label: "Offline" };
}

function renderNavigation(): void
{
    if (state === undefined)
        return;
    const { sessions, runs, rooms, profiles, humanEvents } = state.daemon;
    const signature = JSON.stringify([
        selected?.kind,
        selected?.id,
        humanEvents,
        rooms.map((room) => [room.name, room.unread]),
        profiles.map((profile) => [profile.name, profile.unread, profile.session?.id, profile.session?.status]),
        sessions.map((session) => [session.id, session.title, session.model, session.status, session.profile]),
        runs.filter((run) => !run.sessionId && run.status !== "succeeded").map((run) => [run.id, run.profile, run.status, run.model]),
    ]);
    if (signature === navigationSignature)
        return;
    navigationSignature = signature;
    const active = (kind: string, id: string): string => selected?.kind === kind && selected.id === id ? "active" : "";

    // 1. Coordination Rooms
    const roomItems = rooms.map((room) =>
        `<button type="button" class="nav-item ${active("room", room.name)} ${room.unread ? "unread" : ""}" data-action="select" data-kind="room" data-id="${escape(room.name)}">${icon("hash")}<span class="nav-content"><span class="nav-label">${escape(room.name)}</span></span>${room.unread ? `<span class="badge unread-badge">${room.unread}</span>` : ""}</button>`
    ).join("") || `<div class="nav-empty">No rooms yet</div>`;

    // 2. Agent Profiles
    const profileItems = profiles
        .filter((profile) => profile.name.toLowerCase() !== "human")
        .map((profile) =>
        {
            const status = getProfileStatus(profile);
            const dmItem = `<button type="button" class="nav-item profile-nav-item ${active("dm", profile.name)} ${profile.unread ? "unread" : ""}" data-action="select" data-kind="dm" data-id="${escape(profile.name)}" data-profile="${escape(profile.name)}">${identicon(profile.name, 20)}<span class="nav-content"><span class="nav-label">${escape(profile.name)}</span></span><span class="${status.className}" title="${escape(status.label)}"></span>${profile.unread ? `<span class="badge unread-badge">${profile.unread}</span>` : ""}</button>`;

            let sessionSubItem = "";
            if (profile.session)
            {
                const sess = profile.session;
                sessionSubItem = `<button type="button" class="nav-item nav-sub-item ${active("session", sess.id)}" data-action="select" data-kind="session" data-id="${escape(sess.id)}" title="${escape(sess.title || sess.id)}">${icon("chat-square-text")}<span class="nav-content"><span class="nav-label">${escape(sess.title || sess.id)}</span><span class="nav-meta">${escape(sess.model || "Devin")}</span></span><span class="dot ${escape(sess.status)}" title="${escape(statusLabel(sess.status))}"></span></button>`;
            }
            return `<div class="profile-group">${dmItem}${sessionSubItem}</div>`;
        }).join("") || `<div class="nav-empty">Profiles appear as agents register</div>`;

    // 3. Unassigned Sessions
    const unassignedSessions = sessions.filter((session) =>
        !session.profile && !profiles.some((profile) => profile.session?.id === session.id)
    );
    const unassignedItems = unassignedSessions.map((session) =>
        `<button type="button" class="nav-item ${active("session", session.id)}" data-action="select" data-kind="session" data-id="${escape(session.id)}" title="${escape(session.title || session.id)}">${icon("chat-square-text")}<span class="nav-content"><span class="nav-label">${escape(session.title || session.id)}</span><span class="nav-meta">${escape(session.model || "Devin")}</span></span><span class="dot ${escape(session.status)}" title="${escape(statusLabel(session.status))}"></span></button>`
    );
    for (const run of runs.filter((run) => !run.sessionId && run.status !== "succeeded" && !run.profile))
    {
        unassignedItems.push(`<button type="button" class="nav-item ${active("run", run.id)}" data-action="select" data-kind="run" data-id="${escape(run.id)}">${icon("chat-square-text")}<span class="nav-content"><span class="nav-label">New session</span><span class="nav-meta">${escape(statusLabel(run.status))} · ${escape(run.model)}</span></span><span class="dot ${escape(run.status === "running" ? "starting" : run.status)}"></span></button>`);
    }
    const unassignedHtml = unassignedItems.join("") || `<div class="nav-empty">No unassigned sessions</div>`;

    const navigation = document.getElementById("navigation") as HTMLElement | null;
    if (navigation !== null)
    {
        navigation.innerHTML = `
            <section class="nav-section" id="section-rooms" data-autonom-tier="rooms">
                <header class="section-heading"><span class="eyebrow">Coordination Rooms</span>${iconButton("createRoom", "plus-lg", "Create room")}</header>
                ${roomItems}
            </section>
            <section class="nav-section" id="section-profiles" data-autonom-tier="profiles">
                <header class="section-heading"><span class="eyebrow">Agent Profiles</span></header>
                ${profileItems}
            </section>
            <section class="nav-section" id="section-unassigned" data-autonom-tier="unassigned">
                <header class="section-heading"><span class="eyebrow">Unassigned Sessions</span>${iconButton("newSession", "plus-lg", "New session")}</header>
                ${unassignedHtml}
            </section>
            <button type="button" class="nav-item ${active("pings", "human")}" data-action="pings">
                ${icon("bell")}
                <span class="nav-content"><span class="nav-label">Your pings</span></span>
                ${humanEvents ? `<span class="badge">${humanEvents}</span>` : ""}
            </button>`;
    }
}

function renderInspector(): void
{
    if (state === undefined)
        return;
    const profiles = state.daemon.profiles;
    const signature = JSON.stringify(profiles.map((profile) => [
        profile.name,
        profile.managed,
        profile.session?.status,
        profile.events,
        profile.schedules,
    ]));
    if (signature === inspectorSignature)
        return;
    inspectorSignature = signature;
    const count = document.getElementById("profile-count");
    if (count !== null)
        count.textContent = String(profiles.length);
    const inspector = document.getElementById("inspector") as HTMLElement | null;
    if (inspector !== null)
    {
        inspector.innerHTML = `<span class="eyebrow">Your team</span>${profiles.map((profile) =>
        {
            const profStatus = getProfileStatus(profile, state?.daemon.runs);
            return `<div class="profile-card"><div class="profile-heading">${avatar(profile.name, "small")}<div><strong>${escape(profile.name)}</strong><br><span class="status"><span class="${profStatus.className}"></span>${profile.managed ? escape(profStatus.label) : "Not managed"}</span></div>${iconButton("dm", "chat-square-text", `Message ${profile.name}`, `data-profile="${escape(profile.name)}"`)}</div>
                <div class="profile-meta"><button type="button" data-action="events" data-profile="${escape(profile.name)}">${profile.events} events</button><button type="button" data-action="schedules" data-profile="${escape(profile.name)}">${profile.schedules} schedules</button></div></div>`;
        }).join("") || "<p class=muted>Start an agent to build your team.</p>"}<div class="inspector-note">${icon("shield-check")}Only daemon-managed sessions can use Autonom. Idle sessions release their CLI locks between turns.</div>`;
    }
}

function renderHeader(): void
{
    const header = document.getElementById("conversation-header");
    if (header === null)
        return;

    if (viewMode === "settings")
    {
        header.dataset.signature = "settings";
        header.innerHTML = `${iconButton("back", "arrow-left", "Back to conversation")}${icon("gear")}<div class="conversation-heading"><strong class="conversation-title">Autonom Command Center Settings</strong><span class="conversation-subtitle">Daemon parameters, routing keys, and safety policy</span></div><div class="header-actions"><span class="status"><span class="dot ${state?.connected ? "online running" : "failed offline"}"></span>${state?.connected ? "Connected" : "Disconnected"}</span></div>`;
        return;
    }

    let title = "Workspace";
    let subtitle = "A place for your agents to work together";
    let symbol = "diagram-3-fill";
    let actions = "";
    let avatarMarkup = "";
    if (selected !== undefined)
    {
        const session = state?.daemon.sessions.find((session) => session.id === selected?.id) || transcript?.session;
        if (selected.kind === "session" || selected.kind === "run")
        {
            title = session?.profile || state?.daemon.profiles.find((profile) => profile.session?.id === session?.id)?.name
                || session?.title || session?.id || "New session";
            subtitle = session ? `${session.model || "Devin"} · ${statusLabel(session.status)} · ${session.id}` : "Starting a managed session";
            symbol = "chat-square-text";
            actions = iconButton("removeSession", "trash", "Delete session");
            if (session?.profile)
                avatarMarkup = identicon(session.profile, 22);
        }
        if (selected.kind === "room")
        {
            title = selected.id;
            symbol = "hash";
            const room = state?.daemon.rooms.find((room) => room.name === selected?.id);
            subtitle = `${room?.count ?? 0} messages · Human & agents`;
            actions = iconButton("manageRoom", "sliders", "Room membership and settings");
        }
        if (selected.kind === "dm")
        {
            title = selected.id;
            symbol = "person";
            subtitle = "Direct message · Toggle Ping to wake the agent";
            actions = `<label class="check-row"><input type="checkbox" id="ping-recipient" checked>Ping</label>`;
            avatarMarkup = identicon(title, 22);
        }
        if (selected.kind === "pings")
        {
            title = "Your pings";
            symbol = "bell";
            subtitle = "Messages that need your attention";
        }
    }
    const signature = `${title}|${subtitle}|${selected?.kind}|${viewMode}`;
    if (header.dataset.signature === signature)
        return;
    header.dataset.signature = signature;
    const lead = avatarMarkup || icon(symbol);
    header.innerHTML = `${iconButton("navigation", "layout-sidebar", "Conversations")}${lead}<div class="conversation-heading"><strong class="conversation-title">${escape(title)}</strong><span class="conversation-subtitle">${escape(subtitle)}</span></div><div class="header-actions">${actions}${iconButton("inspector", "people", "Profile statuses")}</div>`;
    header.querySelector('[data-action="navigation"]')?.classList.add("mobile-toggle");
    header.querySelector('[data-action="inspector"]')?.classList.add("inspector-toggle");
}

function renderComposer(): void
{
    const input = document.getElementById("composer-text") as HTMLTextAreaElement | null;
    if (input === null || state === undefined)
        return;
    const agent = selected?.kind === "session" || selected?.kind === "run";
    const session = state.daemon.sessions.find((session) => session.id === selected?.id) || transcript?.session;
    const run = agent ? state.daemon.runs.find((run) => run.id === selected?.id || run.id === session?.executionId) : undefined;
    const active = Boolean(run && ["running", "stopping"].includes(run.status));

    if (composerView)
    {
        composerView.render(state, selected, active, submitting, session?.model, session?.mode as PermissionMode);
        return;
    }

    input.disabled = !state.connected || selected === undefined || selected.kind === "pings"
        || submitting || (agent && (active || session?.status === "loaded"));
    input.placeholder = selected === undefined ? "Choose a conversation" : agent ? "Ask your agent to do something…"
        : selected.kind === "room" ? `Message #${selected.id} · @profile to ping` : `Message ${selected.id}…`;
    const send = document.getElementById("send-button") as HTMLButtonElement;
    send.disabled = !state.connected || (!active && input.disabled);
    send.classList.toggle("stop", active);
    send.innerHTML = icon(active ? "stop-fill" : "arrow-up");
    send.setAttribute("aria-label", active ? "Stop run" : "Send message");
    const model = document.getElementById("composer-model") as HTMLSelectElement | null;
    const mode = document.getElementById("composer-mode") as HTMLSelectElement | null;
    if (model)
    {
        model.hidden = !selected || selected.kind === "pings";
        const desiredModel = session?.model || state.settings.defaultModel || "swe-2-medium";
        const signature = JSON.stringify([state.models, desiredModel, session?.mode, state.settings.permissionMode]);
        if (signature !== modelSignature)
        {
            modelSignature = signature;
            model.innerHTML = modelOptions(state.models, desiredModel);
            const selectedMode = session?.mode === "bypass" || session?.mode === "dangerous" ? "bypass"
                : ["auto", "accept-edits", "smart"].includes(session?.mode || "") ? session?.mode || "auto"
                : state.settings.permissionMode;
            if (mode) mode.innerHTML = modeOptions(selectedMode);
        }
        model.disabled = active;
        if (mode) mode.disabled = active;
    }
    (document.getElementById("composer-caption") as HTMLElement).textContent = active
        ? "Agent is working. Events interrupt it at its next tool call."
        : selected?.kind === "room" || selected?.kind === "dm"
            ? "Messages are sent as human. @mentions surface events and wake idle agents."
            : "Policy screens every tool call. Your conversation stays with the session.";
}

function renderWelcome(): void
{
    const messages = document.getElementById("messages");
    if (messages === null)
        return;
    messages.innerHTML = `<div class="empty-conversation">${brandSvg(32)}<h2>Your agents. One workspace.</h2><p>Start a session, bring your team into a room, and pick up conversations whenever you need.</p><div class="welcome-actions"><button type="button" class="primary" data-action="newSession">${icon("plus-lg")}New session</button><button type="button" class="secondary" data-action="createRoom">${icon("hash")}Create room</button></div></div>`;
}

function renderMessages(message: Extract<HostMessage, { type: "conversation" }>): void
{
    const signature = JSON.stringify([message.destination, message.transcript?.messages, message.entries,
        message.transcript?.execution?.status, message.transcript?.execution?.error]);
    if (signature === conversationSignature)
        return;
    const messages = document.getElementById("messages") as HTMLElement;
    const atBottom = messages.scrollHeight - messages.scrollTop - messages.clientHeight < 100;
    const opened = new Set(Array.from(messages.querySelectorAll<HTMLDetailsElement>("details[open]"))
        .map((detail) => detail.dataset.key));
    const prior = messages.scrollTop;
    const execution = message.transcript?.execution;
    messages.innerHTML = message.transcript ? !message.transcript.messages.length && execution
        && ["failed", "stopped", "interrupted"].includes(execution.status)
        ? emptyConversation(statusLabel(execution.status), execution.error || "The run ended without a reply.")
        : renderConversation(message.transcript.messages) : renderEntries(message.entries);
    for (const detail of messages.querySelectorAll<HTMLDetailsElement>("details"))
        detail.open = opened.has(detail.dataset.key);
    if (atBottom || !conversationSignature)
        messages.scrollTop = messages.scrollHeight;
    else
        messages.scrollTop = prior;
    conversationSignature = signature;
    renderPermissionCards();
}

function renderPermissionCards(): void
{
    const messages = document.getElementById("messages");
    if (messages === null || state === undefined)
        return;
    const pending = state.daemon.permissions.filter((permission) => permission.session === selected?.id);
    const signature = JSON.stringify(pending);
    if (messages.dataset.permissions === signature && messages.querySelectorAll(".permission-card").length === pending.length)
        return;
    messages.dataset.permissions = signature;
    messages.querySelectorAll(".permission-card").forEach((card) => card.remove());
    for (const permission of pending)
        messages.insertAdjacentHTML("beforeend", `<section class="permission-card"><h3>${icon("shield-check")}Permission needed · ${escape(permission.tool)}</h3><p>The workspace policy passed. Choose whether this tool may run once.</p><pre>${escape(JSON.stringify(permission.input, null, 2))}</pre><div class="permission-actions"><button type="button" class="secondary" data-action="permission" data-id="${escape(permission.id)}" data-decision="block">Deny</button><button type="button" class="primary" data-action="permission" data-id="${escape(permission.id)}" data-decision="approve">${icon("check-lg")}Allow once</button></div></section>`);
}

function handleClick(button: HTMLButtonElement): void
{
    const action = button.dataset.action;
    switch (action)
    {
        case "select":
            select({ kind: button.dataset.kind as Destination["kind"], id: button.dataset.id || "" });
            break;
        case "dm":
            select({ kind: "dm", id: button.dataset.profile || "" });
            break;
        case "pings":
            select({ kind: "pings", id: "human" });
            break;
        case "setProvider":
            setProvider(button.dataset.provider || "autonom");
            break;
        case "headerNewSession":
        case "newSession":
            newSession();
            break;
        case "createRoom":
            dialog("Create a room", "create-room-form", `<p class="dialog-description">A shared space for your team. Rooms can be public or limited to selected profiles.</p><label class="field">Room name<input name="name" placeholder="general" pattern="[a-zA-Z0-9][a-zA-Z0-9_\\-]{0,63}" required></label>`, "Create room");
            break;
        case "manageRoom":
            manageRoom();
            break;
        case "schedules":
            scheduleDialog(button.dataset.profile || "");
            break;
        case "events":
            selectedProfile = button.dataset.profile || "";
            dialog(`${selectedProfile} · pending events`, "events-form", "<div id=event-list></div>");
            bridge.postMessage({ type: "loadEvents", profile: selectedProfile });
            break;
        case "cancelSchedule":
            bridge.postMessage({ type: "cancelSchedule", profile: selectedProfile, id: button.dataset.id || "" });
            break;
        case "permission":
            bridge.postMessage({ type: "permission", id: button.dataset.id || "", decision: button.dataset.decision === "approve" ? "approve" : "block" });
            break;
        case "removeSession":
            if (selected?.kind === "session")
                bridge.postMessage({ type: "removeSession", id: selected.id, run: false });
            break;
        case "deleteRoom":
            if (selected?.kind === "room")
                bridge.postMessage({ type: "deleteRoom", name: selected.id });
            break;
        case "removeAdmin":
            if (selected?.kind === "room")
                bridge.postMessage({ type: "roomAdmin", name: selected.id, profile: button.dataset.profile || "", remove: true });
            break;
        case "settings":
            if (isSidebar)
                bridge.postMessage({ type: "settings" });
            else
                switchViewMode(viewMode === "settings" ? "conversation" : "settings");
            break;
        case "back":
        case "closeSettings":
            switchViewMode("conversation");
            break;
        case "toggleProvider": {
            const toggle = document.getElementById("autonom-provider-toggle") as HTMLInputElement | null;
            setProvider(toggle?.checked ? "autonom" : "devin-cloud");
            break;
        }
        case "refresh":
            bridge.postMessage({ type: "refresh" });
            break;
        case "navigation":
            document.body.classList.remove("inspector-open");
            document.body.classList.toggle("navigation-open");
            break;
        case "inspector":
            document.body.classList.remove("navigation-open");
            document.body.classList.toggle("inspector-open");
            break;
        case "close":
            closeDialog();
            break;
    }
}

function submit(form: HTMLFormElement): void
{
    if (state === undefined)
        return;
    if (form.id === "composer")
    {
        if (selected === undefined)
            return;
        const session = state.daemon.sessions.find((session) => session.id === selected?.id) || transcript?.session;
        const run = state.daemon.runs.find((run) => run.id === selected?.id || run.id === session?.executionId);
        if (["session", "run"].includes(selected.kind) && run && ["running", "stopping"].includes(run.status))
        {
            bridge.postMessage({ type: "stop", id: run.id, run: true });
            return;
        }
        const prompt = field(form, "text");
        if (!prompt.trim() || submitting)
            return;
        if (selected.kind === "session")
            bridge.postMessage({ type: "resume", session: selected.id, prompt, model: field(form, "model"), mode: field(form, "mode") as PermissionMode });
        else if (selected.kind === "room" || selected.kind === "dm")
        {
            const matches = prompt.matchAll(/@([a-zA-Z0-9][a-zA-Z0-9_-]{0,63})/g);
            const ping = new Set(Array.from(matches).map((match) => match[1] || "")
                .filter((name) => state?.daemon.profiles.some((profile) => profile.name === name.toLowerCase())));
            if (selected.kind === "dm" && (document.getElementById("ping-recipient") as HTMLInputElement | null)?.checked)
                ping.add(selected.id);
            bridge.postMessage({ type: "post", source: selected.kind, target: selected.id, text: prompt,
                ping: Array.from(ping).map((name) => name.toLowerCase()) });
        }
        else
            return;
        submitting = true;
        renderComposer();
    }
    if (form.id === "new-session-form")
    {
        if (submitting)
            return;
        const button = form.querySelector<HTMLButtonElement>('button[type="submit"]');
        if (button !== null)
            button.disabled = true;

        bridge.postMessage({ type: "start", prompt: field(form, "prompt"), profile: field(form, "profile"),
            model: field(form, "model"), mode: field(form, "mode") as PermissionMode });
        submitting = true;
    }
    if (form.id === "create-room-form")
    {
        if (submitting)
            return;
        const button = form.querySelector<HTMLButtonElement>('button[type="submit"]');
        if (button !== null)
            button.disabled = true;
        submitting = true;
        bridge.postMessage({ type: "createRoom", name: field(form, "name") });
    }
    if (form.id === "room-form" && selected?.kind === "room")
    {
        const values = new FormData(form);
        bridge.postMessage({ type: "membership", name: selected.id, involved: values.has("restricted")
            ? values.getAll("members").map(String) : null });
        const profile = field(form, "admin");
        if (profile)
            bridge.postMessage({ type: "roomAdmin", name: selected.id, profile, remove: false });
    }
    if (form.id === "schedule-form")
    {
        if (submitting)
            return;
        const button = form.querySelector<HTMLButtonElement>('button[type="submit"]');
        if (button !== null)
            button.disabled = true;
        submitting = true;
        const type = field(form, "scheduleType");
        const schedule: Record<string, unknown> = { type };
        if (type === "clock")
        {
            if (field(form, "every"))
                schedule.every = Number(field(form, "every"));
            else if (field(form, "at"))
                schedule.at = new Date(field(form, "at")).toISOString();
        }
        else
        {
            if (type === "room")
                schedule.room = field(form, "room");
            if (field(form, "from"))
                schedule.from = field(form, "from");
        }
        bridge.postMessage({ type: "schedule", profile: selectedProfile, schedule });
    }
}

function newSession(): void
{
    if (state === undefined)
        return;
    dialog("New session", "new-session-form", `<p class="dialog-description">Start a daemon-managed agent in <strong>${escape(state.workspaceName)}</strong>. It can pause, receive events, and resume without Desktop's agent panel.</p>
        <label class="field">Profile name <small>Optional · give the agent an identity for rooms and DMs</small><input name="profile" placeholder="e.g. architect" maxlength="64" pattern="[a-zA-Z0-9][a-zA-Z0-9_\\-]{0,63}"></label>
        <div class="field-row"><label class="field">Model<select name="model">${modelOptions(state.models, state.settings.defaultModel || "swe-2-medium")}</select></label><label class="field">Permissions<select name="mode">${modeOptions(state.settings.permissionMode)}</select></label></div>
        <label class="field">What should the agent do?<textarea name="prompt" rows="5" placeholder="Describe the task. The agent can use your workspace tools, skills, and Autonom coordination." required maxlength="48000"></textarea></label>
        <p class="dialog-description">Workspace policy applies in every mode, including bypass.</p>`, "Start session");
}

function manageRoom(): void
{
    const room = state?.daemon.rooms.find((room) => room.name === selected?.id);
    if (room === undefined || state === undefined)
        return;
    dialog(`#${room.name} · settings`, "room-form", `<p class="dialog-description">Owned by ${escape(room.membership.owner)}. You administer every room as the human profile.</p>
        <label class="check-row"><input name="restricted" type="checkbox" ${room.membership.involved !== null ? "checked" : ""}>Restrict room membership</label>
        <div id="membership-list" ${room.membership.involved === null ? "hidden" : ""}>${state.daemon.profiles.map((profile) => `<label class="check-row"><input name="members" type="checkbox" value="${escape(profile.name)}" ${room.membership.involved?.includes(profile.name) ? "checked" : ""}>${escape(profile.name)}</label>`).join("")}</div>
        <p class="eyebrow">Administrators</p>${room.membership.admins.map((profile) => `<div class="schedule-card"><div>${escape(profile)}</div>${iconButton("removeAdmin", "x-lg", "Remove administrator", `data-profile="${escape(profile)}"`)}</div>`).join("")}
        <label class="field">Add administrator<select name="admin"><option value="">Choose a profile</option>${state.daemon.profiles.filter((profile) => !room.membership.admins.includes(profile.name)).map((profile) => `<option>${escape(profile.name)}</option>`).join("")}</select></label>
        <button class="danger-button" type="button" data-action="deleteRoom">${icon("trash")}Delete room</button>`, "Save membership");
}

function scheduleDialog(profile: string): void
{
    selectedProfile = profile;
    schedules = [];
    dialog(`${profile} · schedules`, "schedule-form", `<div id="schedule-list"></div><p class="eyebrow">New schedule</p><label class="field">Wake on<select name="scheduleType"><option value="ping">Ping</option><option value="dm">Direct message</option><option value="room">Room message</option><option value="clock">Clock</option></select></label><div id="schedule-fields"></div><p class="dialog-description">Scheduled wakes preserve the conversation. Idle managed agents resume automatically.</p>`, "Add schedule");
    renderScheduleFields("ping");
    bridge.postMessage({ type: "loadSchedules", profile });
}

function renderScheduleFields(type: string): void
{
    const fields = document.getElementById("schedule-fields");
    if (fields === null)
        return;
    if (type === "clock")
        fields.innerHTML = `<label class="field">One-shot wake time<input name="at" type="datetime-local" step="1"><small>Local time. Leave blank for an interval.</small></label><label class="field">Recurring interval (seconds)<input name="every" type="number" min="1" max="2592000" placeholder="Leave blank for a one-shot wake"></label>`;
    else
        fields.innerHTML = `${type === "room" ? `<label class="field">Room<select name="room">${state?.daemon.rooms.map((room) => `<option>${escape(room.name)}</option>`).join("")}</select></label>` : ""}<label class="field">From profile<select name="from"><option value="">Anyone</option>${state?.daemon.profiles.map((profile) => `<option>${escape(profile.name)}</option>`).join("")}</select></label>`;
}

function renderScheduleList(): void
{
    const list = document.getElementById("schedule-list");
    if (list === null)
        return;
    list.innerHTML = schedules.length ? schedules.map((schedule) => `<div class="schedule-card">${icon("clock")}<div><strong>${escape(schedule.type === "room" ? "#" + schedule.room : schedule.type)}</strong><p>${escape(schedule.type === "clock" ? schedule.every ? `Every ${schedule.every}s` : schedule.at || "One-shot" : schedule.from ? `From ${schedule.from}` : "From anyone")}</p></div>${iconButton("cancelSchedule", "trash", "Cancel schedule", `data-id="${escape(schedule.id)}"`)}</div>`).join("") : "<p class=dialog-description>No schedules yet.</p>";
}

function renderEvents(events: Event[]): void
{
    const list = document.getElementById("event-list");
    if (list === null)
        return;
    list.innerHTML = events.length ? events.map((event) => `<div class="schedule-card">${icon("bell")}<div><strong>${escape(event.type)}${event.from ? ` from ${escape(event.from)}` : ""}</strong><p>${escape(event.text)}</p></div><span class="muted">${escape(relativeTime(event.ts))}</span></div>`).join("") : "<p class=dialog-description>No unread events. Viewing does not clear the agent's inbox.</p>";
}

function dialog(title: string, id: string, body: string, submit = ""): void
{
    modalRoot.innerHTML = `<div class="overlay"><form id="${escape(id)}" class="dialog" role="dialog" aria-modal="true" aria-labelledby="dialog-title"><header class="dialog-header"><h2 id="dialog-title">${escape(title)}</h2>${iconButton("close", "x-lg", "Close dialog")}</header><div class="dialog-body">${body}</div>${submit ? `<footer class="dialog-footer"><button type="button" class="secondary" data-action="close">Cancel</button><button type="submit" class="primary">${escape(submit)}</button></footer>` : ""}</form></div>`;
    window.setTimeout(() => modalRoot.querySelector<HTMLInputElement>("input, textarea, select")?.focus(), 10);
}

function closeDialog(): void
{
    modalRoot.replaceChildren();
    selectedProfile = "";
    submitting = false;
}
