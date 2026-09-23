// Team room client. No framework: one host connection, one list, one composer.
// The extension host owns the bus; this file only renders what it posts and
// sends back what the user does.

const vscode = acquireVsCodeApi();
const post = (message) => vscode.postMessage(message);

const state = {
    messages: [],
    rooms: [],
    agents: [],
    seen: JSON.parse(localStorage.getItem("coord-room-seen") ?? "{}"),
    room: null,
    dm: null,
    human: "user",
    project: "team",
    teamRoom: "general",
    connected: false,
};

const el = {
    rooms: document.getElementById("rooms"),
    dms: document.getElementById("dms"),
    messages: document.getElementById("messages"),
    count: document.getElementById("count"),
    conn: document.getElementById("conn"),
    build: document.getElementById("build"),
    menu: document.getElementById("menu"),
    text: document.getElementById("text"),
    composer: document.getElementById("composer"),
    hint: document.getElementById("hint"),
    mentions: document.getElementById("mentions"),
    toast: document.getElementById("toast"),
};

function esc(text)
{
    return String(text ?? "").replace(/[&<>"']/g, (ch) =>
        ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
}

function displayName(id)
{
    return state.agents.find((agent) => agent.id === id)?.display || id;
}

// A stable muted color per seat — the identity's own color when it has one,
// otherwise a deterministic palette entry, so a seat keeps its color across
// workspaces and no per-project name list is needed. The human gets the
// accent-warm --human tone rather than a palette entry.
const SEAT_COLORS = ["#6d9ce8", "#5ec9a0", "#b78fe0", "#d99a55", "#5fc4cb", "#d9899e", "#a3bb6a", "#8f9ede"];
function seatColor(id)
{
    if (id === state.human)
        return "var(--human)";
    const own = state.agents.find((agent) => agent.id === id)?.color;
    if (own)
        return own;
    let hash = 0;
    for (const ch of String(id))
        hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
    return SEAT_COLORS[hash % SEAT_COLORS.length];
}

// Seat colors are applied through CSSOM, not `style=` attributes: the webview
// CSP blocks inline style attributes, and this keeps style-src strict.
function paintColors(root)
{
    for (const node of root.querySelectorAll("[data-color]"))
        node.style.color = node.dataset.color;
}

// The seats that can be pinged, plus @everyone. The human is excluded: pinging
// yourself is not a ping. #room pings every member of that room.
function mentionCandidates(sigil)
{
    if (sigil === "#")
        return state.rooms.map((room) => ({ name: room.name, role: `every member of #${room.name}` }));
    const ret = [{ name: "everyone", role: "every seat in the room" }];
    for (const agent of state.agents)
        if (agent.id !== state.human)
            ret.push({ name: agent.id, role: displayName(agent.id) });
    return ret;
}

function knownMentions()
{
    return new Set(["everyone", ...state.agents.map((agent) => agent.id)]);
}

// A ping is a room message that names the human or everyone. Such a message is
// marked in the log rather than left to look like ordinary chatter.
function isPing(message)
{
    if (message.stream !== "room")
        return false;
    const me = state.human.toLowerCase();
    for (const match of (message.text ?? "").matchAll(/@([A-Za-z0-9_-]+)/g))
    {
        const name = match[1].toLowerCase();
        if (name === "everyone" || name === "all" || name === me)
            return true;
    }
    for (const match of (message.text ?? "").matchAll(/#([A-Za-z0-9_-]+)/g))
        if (state.rooms.some((room) => room.name === match[1] && room.members.includes(state.human)))
            return true;
    return false;
}

// Pings are fanned out to inboxes as `[PING] ...` DMs; the room view already
// shows the original, so the mirror is noise there and only noise.
function isPingMirror(message)
{
    return message.stream === "dm" && typeof message.text === "string" && message.text.startsWith("[PING]");
}

function renderText(text)
{
    const known = knownMentions();
    const me = state.human.toLowerCase();
    return esc(text)
        .replace(/`([^`\n]+)`/g, "<code>$1</code>")
        .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
        .replace(/(https?:\/\/[^\s<)&"'`]+[^\s<).,;:!?"'`])/g, '<a href="$1">$1</a>')
        .replace(/([@#])([A-Za-z0-9_-]+)/g, (full, sigil, name) =>
        {
            if (sigil === "#")
            {
                if (!state.rooms.some((room) => room.name === name))
                    return full;
                return `<span class="mention">#${esc(name)}</span>`;
            }
            const lower = name.toLowerCase();
            const isMe = lower === me;
            if (!known.has(name) && !isMe)
                return full;
            const extra = lower === "everyone" ? " everyone" : (isMe ? " you" : "");
            return `<span class="mention${extra}">@${esc(name)}</span>`;
        });
}

let toastTimer = null;
function toast(text, tone)
{
    el.toast.textContent = text;
    el.toast.className = `toast ${tone ?? ""}`;
    el.toast.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.toast.hidden = true; }, 6000);
}

function clock(ts)
{
    return new Date(ts).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function visible(message)
{
    if (isPingMirror(message))
        return false;
    if (state.dm)
    {
        // A 1:1 shows both directions of that conversation and nothing else.
        if (message.stream !== "dm" || (message.from !== state.dm && message.to !== state.dm))
            return false;
    }
    else
    {
        // A room view shows only that room's messages — DMs never bleed in.
        if (message.stream === "dm")
            return false;
        if (state.room && message.stream === "room" && message.room !== state.room)
            return false;
    }
    return true;
}

// Scroll modes: "force" lands at the newest line (view switch, first load,
// your own send); "auto" follows only when the view is already at the bottom,
// so reading backscroll never gets yanked; anything else leaves it alone.
function renderMessages(scroll = "force")
{
    const nearBottom = el.messages.scrollHeight - el.messages.scrollTop - el.messages.clientHeight < 80;
    const shown = state.messages.filter(visible);
    let prev = null;
    el.messages.innerHTML = shown.map((m) =>
    {
        const mine = m.from === state.human;
        // A run of consecutive messages from one sender shows the name once —
        // on the first. A ping still earns its full meta row, and a stream,
        // room, or long time gap ends the run even from the same sender.
        const merged = prev !== null
            && prev.from === m.from
            && prev.stream === m.stream
            && (prev.room ?? null) === (m.room ?? null)
            && m.ts - prev.ts < 5 * 60_000
            && !isPing(m);
        prev = m;
        const tag = m.stream === "room" && !state.room ? `<span class="tag">#${esc(m.room ?? "")}</span>` : "";
        const badge = m.kind ? `<span class="badge ${esc(m.kind)}">${esc(m.kind)}</span>` : "";
        const ping = isPing(m) ? "ping" : "";
        const meta = merged
            ? (badge || tag ? `<div class="meta">${badge}${tag}</div>` : "")
            : `<div class="meta"><span class="who" data-color="${esc(seatColor(m.from))}">${esc(displayName(m.from))}</span>${badge}${tag}</div>`;
        return `<li class="msg ${m.stream === "dm" ? "dm" : ""} ${ping} ${mine ? "me" : ""} ${merged ? "merged" : ""}" data-id="${esc(m.id ?? "")}">
            <span class="when" title="${new Date(m.ts).toLocaleString()}">${clock(m.ts)}</span>
            <div class="body">
                ${meta}
                <div class="text">${renderText(m.text ?? "")}</div>
            </div>
        </li>`;
    }).join("");
    paintColors(el.messages);
    el.count.textContent = `${shown.length} / ${state.messages.length}`;
    if (scroll === "force" || (scroll === "auto" && nearBottom))
        el.messages.scrollTop = el.messages.scrollHeight;
}

function renderSidebar()
{
    el.rooms.innerHTML = state.rooms.map((room) =>
    {
        const last = room.lastTs ? state.seen[room.name] ?? 0 : Infinity;
        const unread = (room.lastTs ?? 0) > last;
        const active = state.room === room.name ? "active" : "";
        return `<li class="${active} ${unread ? "unread" : ""}" data-room="${esc(room.name)}" title="${esc(room.topic)}">
            <span class="name">#${esc(room.name)}</span>
            <span class="meta">${room.count} · ${room.members.length} seats</span>
        </li>`;
    }).join("");

    renderDms();

    const { mode, name } = destination();
    el.text.placeholder = mode === "dm"
        ? `Message ${displayName(name)} — only they see it`
        : `Message #${name} — @mention or #room`;
}

// A seat is as alive as its last bus touch — a message it sent or a read
// cursor its coord server moved. Thirty silent minutes means gone: it sinks
// out of the list entirely unless it left unread pings (those dim instead).
// The list doubles as the DM target picker, so a hidden seat cannot be written
// to at all — hiding is a reachability claim, not just decluttering.
const DM_INACTIVE_MS = 30 * 60_000;

function renderDms()
{
    const unreadFor = (agent) => state.messages.filter((message) =>
        message.stream === "dm" && message.from === agent.id && message.to === state.human
        && !isPingMirror(message)
        && message.ts > (state.seen[`dm:${agent.id}`] ?? 0)).length;

    const shown = state.agents
        .filter((agent) => agent.id !== state.human
            && (Date.now() - (agent.lastActive ?? 0) < DM_INACTIVE_MS || unreadFor(agent) > 0))
        .sort((a, b) => (b.lastActive ?? 0) - (a.lastActive ?? 0));

    el.dms.innerHTML = shown.map((agent) =>
    {
        const unread = unreadFor(agent);
        const active = state.dm === agent.id ? "active" : "";
        const stale = agent.online ? "" : "offline";
        return `<li class="${active} ${stale}" data-dm="${esc(agent.id)}" title="1:1 with ${esc(displayName(agent.id))}">
            <span class="name" data-color="${esc(seatColor(agent.id))}">${esc(displayName(agent.id))}</span>
            <span class="meta">${unread ? `${unread} unread` : "1:1"}</span>
        </li>`;
    }).join("");
    paintColors(el.dms);
}

// Where the next message goes. There is no destination control: the view you
// are looking at IS the destination, which is why the sidebar and the composer
// placeholder have to agree at all times.
function destination()
{
    if (state.dm)
        return { mode: "dm", name: state.dm };
    return { mode: "room", name: state.room ?? state.teamRoom };
}

function openDm(seat)
{
    state.dm = seat;
    state.room = null;
    markSeen();
    renderSidebar();
    renderMessages();
    el.text.focus();
    el.hint.textContent = "";
}

function renderBuild(payload)
{
    // Which build is live is a fact the user can glance at, not something
    // inferred from a PID. Stale code shows up as a version that never changes.
    if (payload.build)
    {
        el.build.textContent = `v${payload.build}`;
        el.build.title = `team room ${payload.build}`;
    }
}

function absorb(payload)
{
    state.human = payload.human;
    state.project = payload.project ?? state.project;
    state.teamRoom = payload.teamRoom;
    state.rooms = payload.rooms;
    state.agents = payload.agents;
    if (!state.room && !state.dm)
        state.room = state.teamRoom;
    renderSidebar();
    renderBuild(payload);
}

function markSeen()
{
    for (const message of state.messages)
    {
        if (message.stream === "room")
            state.seen[message.room] = Math.max(state.seen[message.room] ?? 0, message.ts);
        else if (state.dm && message.from === state.dm)
            state.seen[`dm:${state.dm}`] = Math.max(state.seen[`dm:${state.dm}`] ?? 0, message.ts);
    }
    localStorage.setItem("coord-room-seen", JSON.stringify(state.seen));
}

function addMessages(incoming)
{
    const known = new Set(state.messages.map((m) => m.id));
    let added = false;
    for (const message of incoming)
        if (!known.has(message.id))
        {
            state.messages.push(message);
            added = true;
        }
    if (added)
        state.messages.sort((a, b) => a.ts - b.ts);
    return added;
}

// The host pushes state on connect and after every structural change; the
// interval below is the recovery path if a push was missed. Silence for longer
// than STALE_MS is treated as a dropped connection, not a quiet room: the view
// asks for a refresh and says so, so a stuck room heals without a reload.
const STALE_MS = 20_000;
let lastHostAt = Date.now();
let stale = false;

// A batch of entries that arrived together renders once. The host posts the
// whole pump as one message for exactly this reason.
//
// Only scroll for a message the current view actually shows — traffic in
// another room shouldn't yank the scroll position. Your own sends snap to
// bottom unconditionally; anything else follows only when you're already there.
function receive(entries)
{
    if (!addMessages(entries))
        return;
    const shown = entries.filter(visible);
    const mine = shown.some((entry) => entry.from === state.human);
    renderMessages(shown.length ? (mine ? "force" : "auto") : "none");
    markSeen();
    renderSidebar();
}

window.addEventListener("message", (event) =>
{
    const payload = event.data ?? {};
    lastHostAt = Date.now();
    stale = false;
    if (payload.type === "state")
    {
        absorb(payload);
        const added = addMessages(payload.messages);
        state.connected = true;
        el.conn.textContent = "live";
        el.conn.className = "conn live";
        if (added)
            renderMessages();
        markSeen();
        renderSidebar();
    }
    else if (payload.type === "message")
        receive([payload.entry]);
    else if (payload.type === "messages")
        receive(payload.entries ?? []);
    else if (payload.type === "conn")
    {
        state.connected = payload.up;
        el.conn.textContent = payload.up ? "live" : "offline";
        el.conn.className = `conn ${payload.up ? "live" : "dead"}`;
    }
    else if (payload.type === "sent")
    {
        if (payload.ok)
        {
            el.hint.textContent = "";
            closeMentions();
            if (payload.pinged?.length)
                toast(`pinged ${payload.pinged.map((name) => `@${name}`).join(", ")} — delivered to their inbox`, "good");
        }
        else
        {
            el.hint.textContent = `not sent: ${payload.error}`;
            toast(`not sent: ${payload.error}`, "bad");
        }
    }
    else if (payload.type === "toast")
        toast(payload.text, payload.tone);
});

async function send()
{
    const text = el.text.value.trim();
    if (!text)
        return;
    const { mode, name } = destination();
    el.text.value = "";
    el.hint.textContent = "sending…";
    if (mode === "dm")
        post({ type: "dm", to: name, text });
    else
        post({ type: "say", room: name, text });
}

el.composer.addEventListener("submit", (event) =>
{
    event.preventDefault();
    send();
});

const mentionState = { open: false, items: [], active: 0, start: -1 };

function closeMentions()
{
    mentionState.open = false;
    mentionState.items = [];
    mentionState.start = -1;
    el.mentions.hidden = true;
    el.mentions.innerHTML = "";
}

function renderMentions()
{
    const sigil = mentionState.sigil ?? "@";
    el.mentions.innerHTML = mentionState.items.map((item, index) =>
        `<li data-name="${esc(item.name)}" class="${index === mentionState.active ? "active" : ""}">
            <span class="who" data-color="${sigil === "#" ? "var(--accent)" : esc(seatColor(item.name))}">${sigil}${esc(item.name)}</span>
            <span class="meta">${esc(item.role)}</span>
        </li>`).join("");
    paintColors(el.mentions);
}

// The @token the caret is sitting in, if any. The @ has to start a word, so
// `user@host` does not open the list.
function mentionQuery()
{
    const caret = el.text.selectionStart;
    const match = /(^|[\s(])([@#])([A-Za-z0-9_-]*)$/.exec(el.text.value.slice(0, caret));
    if (!match)
        return null;
    return { query: match[3].toLowerCase(), sigil: match[2], start: caret - match[3].length - 1 };
}

function updateMentions()
{
    const found = mentionQuery();
    const items = found
        ? mentionCandidates(found.sigil).filter((item) => item.name.toLowerCase().startsWith(found.query))
        : [];

    if (items.length === 0)
    {
        closeMentions();
        return;
    }

    mentionState.open = true;
    mentionState.items = items;
    mentionState.active = 0;
    mentionState.start = found.start;
    mentionState.sigil = found.sigil;
    el.mentions.hidden = false;
    renderMentions();
}

function acceptMention(item)
{
    if (!item)
        return;
    const caret = el.text.selectionStart;
    const before = el.text.value.slice(0, mentionState.start);
    const after = el.text.value.slice(caret);
    el.text.value = `${before}${mentionState.sigil ?? "@"}${item.name} ${after}`;
    const at = before.length + item.name.length + 2;
    el.text.setSelectionRange(at, at);
    closeMentions();
    el.text.focus();
}

el.text.addEventListener("input", updateMentions);

el.text.addEventListener("keydown", (event) =>
{
    if (event.isComposing)
        return;

    if (mentionState.open)
    {
        if (event.key === "ArrowDown" || event.key === "ArrowUp")
        {
            event.preventDefault();
            const step = event.key === "ArrowDown" ? 1 : -1;
            mentionState.active = (mentionState.active + step + mentionState.items.length) % mentionState.items.length;
            renderMentions();
            return;
        }
        if (event.key === "Enter" || event.key === "Tab")
        {
            event.preventDefault();
            acceptMention(mentionState.items[mentionState.active]);
            return;
        }
        if (event.key === "Escape")
        {
            event.preventDefault();
            closeMentions();
            return;
        }
    }

    // Enter sends. Shift+enter is the newline. Ctrl+enter still sends, for habit.
    if (event.key === "Enter" && (!event.shiftKey || event.ctrlKey || event.metaKey))
    {
        event.preventDefault();
        send();
    }
});

// Keep focus in the composer while the list is being clicked.
el.mentions.addEventListener("mousedown", (event) => event.preventDefault());

el.mentions.addEventListener("click", (event) =>
{
    const row = event.target.closest("li[data-name]");
    if (row)
        acceptMention(mentionState.items.find((item) => item.name === row.dataset.name));
});

// The sidebar is a slide-over drawer on narrow screens — the ☰ button opens
// it, and picking a room or a seat closes it again.
el.menu.addEventListener("click", () => document.body.classList.toggle("sidebar-open"));

el.rooms.addEventListener("click", (event) =>
{
    const row = event.target.closest("li[data-room]");
    if (!row || !row.dataset.room)
        return;
    state.dm = null;
    state.room = row.dataset.room;
    document.body.classList.remove("sidebar-open");
    markSeen();
    renderSidebar();
    renderMessages();
});

el.dms.addEventListener("click", (event) =>
{
    const row = event.target.closest("li[data-dm]");
    if (row && row.dataset.dm !== state.human)
    {
        document.body.classList.remove("sidebar-open");
        openDm(row.dataset.dm);
    }
});

// External links open in the real browser, not inside the webview iframe.
el.messages.addEventListener("click", (event) =>
{
    const link = event.target.closest("a[href]");
    if (link)
    {
        event.preventDefault();
        post({ type: "openLink", href: link.href });
    }
});

// The host pushes state on connect and after every structural change; this is
// only a recovery path if a push was missed.
setInterval(() =>
{
    if (Date.now() - lastHostAt <= STALE_MS)
        return;
    post({ type: "refresh" });
    if (!stale)
    {
        stale = true;
        el.conn.textContent = "reconnecting…";
        el.conn.className = "conn dead";
    }
}, 5_000);

// Coming back to the window is the moment the view is most likely to be
// showing something stale, so it asks then rather than waiting for the tick.
// (Editor-tab switches are the host's job — it already pushes state when the
// view or panel becomes visible again.)
document.addEventListener("visibilitychange", () =>
{
    if (!document.hidden)
        post({ type: "refresh" });
});

post({ type: "ready" });
