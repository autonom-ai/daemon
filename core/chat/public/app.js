// Team chat client. No framework: one stream, one list, one composer.

const state = {
    messages: [],
    rooms: [],
    agents: [],
    seen: JSON.parse(localStorage.getItem("coord-chat-seen") ?? "{}"),
    room: null,
    dm: null,
    human: "cet",
    project: "team",
    teamRoom: "general",
    standDown: false,
    recess: { active: false },
};

const el = {
    rooms: document.getElementById("rooms"),
    dms: document.getElementById("dms"),
    composeMode: document.getElementById("compose-mode"),
    messages: document.getElementById("messages"),
    count: document.getElementById("count"),
    conn: document.getElementById("conn"),
    build: document.getElementById("build"),
    search: document.getElementById("search"),
    autoscroll: document.getElementById("autoscroll"),
    menu: document.getElementById("menu"),
    kind: document.getElementById("kind"),
    text: document.getElementById("text"),
    composer: document.getElementById("composer"),
    hint: document.getElementById("hint"),
    standDown: document.getElementById("standdown"),
    standDownBanner: document.getElementById("standdown-banner"),
    recess: document.getElementById("recess"),
    recessBanner: document.getElementById("recess-banner"),
    recessWhen: document.getElementById("recess-when"),
    recessEnd: document.getElementById("recess-end"),
    mentions: document.getElementById("mentions"),
    toast: document.getElementById("toast"),
    recessDialog: document.getElementById("recess-dialog"),
    recessDialogTitle: document.getElementById("recess-dialog-title"),
    recessDialogLede: document.getElementById("recess-dialog-lede"),
    recessNote: document.getElementById("recess-note"),
    recessConfirm: document.getElementById("recess-confirm"),
    recessCancel: document.getElementById("recess-cancel"),
};

// The seats that can be pinged, plus @everyone. `cet` is excluded: pinging
// yourself is not a ping.
function mentionCandidates()
{
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

// Every @name in `text` that names a real seat. Unknown @words are left alone,
// so an email address or a stray @ does not become a ping.
function mentionTokens(text)
{
    const known = knownMentions();
    const ret = [];
    const pattern = /@([A-Za-z0-9_-]+)/g;
    let match;
    while ((match = pattern.exec(text ?? "")) !== null)
        if (known.has(match[1]) && !ret.includes(match[1]))
            ret.push(match[1]);
    return ret;
}

// A ping is a room message that names cet or everyone. This is the "priority #1"
// rule made visible: such a message is marked in the log rather than left to look
// like ordinary chatter.
function isPing(message)
{
    if (message.stream !== "room")
        return false;
    return mentionTokens(message.text).some((name) => name === "everyone" || name === state.human);
}

function esc(text)
{
    return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

// The display name for a seat: the role/displayName if set, otherwise the raw id.
function displayName(id)
{
    const agent = state.agents.find((a) => a.id === id);
    return (agent && agent.role) ? agent.role : id;
}

// A stable muted color per seat — deterministic, so a seat keeps its color
// across workspaces and no per-project name list is needed. The human gets
// the accent-warm --human tone rather than a palette entry.
const SEAT_COLORS = ["#7fa6d9", "#6fbf9a", "#b08fd4", "#d1a06a", "#7fbfc4", "#c9879b", "#9ab06b", "#8f9ed0"];
function seatColor(id)
{
    if (id === state.human)
        return "var(--human)";
    let hash = 0;
    for (const ch of String(id))
        hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
    return SEAT_COLORS[hash % SEAT_COLORS.length];
}

function renderText(text)
{
    const known = knownMentions();
    return esc(text)
        .replace(/`([^`\n]+)`/g, "<code>$1</code>")
        .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
        .replace(/(https?:\/\/[^\s<)&"'`]+[^\s<).,;:!?"'`])/g, '<a href="$1" target="_blank" rel="noopener">$1</a>')
        .replace(/@([A-Za-z0-9_-]+)/g, (full, name) =>
        {
            if (!known.has(name))
                return full;
            const extra = name === "everyone" ? " everyone" : (name === state.human ? " you" : "");
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
    const query = el.search.value.trim().toLowerCase();
    if (query && !`${message.from} ${message.text}`.toLowerCase().includes(query))
        return false;
    return true;
}

function renderMessages()
{
    const shown = state.messages.filter(visible);
    el.messages.innerHTML = shown.map((m) =>
    {
        const mine = m.from === state.human;
        const tag = m.stream === "dm" ? `<span class="tag">dm ${mine ? "→ " + esc(displayName(m.to ?? "")) : "from " + esc(displayName(m.from))}</span>`
            : (state.room ? "" : `<span class="tag">#${esc(m.room ?? "")}</span>`);
        const badge = m.kind ? `<span class="badge ${esc(m.kind)}">${esc(m.kind)}</span>` : "";
        const ping = isPing(m) ? "ping" : "";
        return `<li class="msg ${m.stream === "dm" ? "dm" : ""} ${ping} ${mine ? "me" : ""}" data-id="${esc(m.id ?? "")}">
            <span class="when" title="${new Date(m.ts).toLocaleString()}">${clock(m.ts)}</span>
            <div class="body">
                <div class="meta"><span class="who" style="color:${seatColor(m.from)}">${esc(displayName(m.from))}</span>${badge}${tag}</div>
                <div class="text">${renderText(m.text ?? "")}</div>
            </div>
        </li>`;
    }).join("");
    el.count.textContent = `${shown.length} / ${state.messages.length}`;
    if (el.autoscroll.checked)
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

    renderComposeMode();
}

function renderDms()
{
    el.dms.innerHTML = state.agents.map((agent) =>
    {
        const isMe = agent.id === state.human;
        const unread = state.messages.filter((message) =>
            message.stream === "dm" && message.from === agent.id && message.to === state.human
            && message.ts > (state.seen[`dm:${agent.id}`] ?? 0)).length;
        const active = state.dm === agent.id ? "active" : "";
        const dot = agent.online ? "online" : "offline";
        const label = isMe ? `${esc(displayName(agent.id))} (you)` : esc(displayName(agent.id));
        return `<li class="${active} ${dot} ${isMe ? "me" : ""}" data-dm="${esc(agent.id)}" title="1:1 with ${esc(displayName(agent.id))}">
            <span class="presence ${dot}"></span>
            <span class="name">${label}</span>
            <span class="meta">${isMe ? "" : unread ? `${unread} unread` : "1:1"}</span>
        </li>`;
    }).join("");
}

// Where the next message goes. There is no destination control: the view you are
// looking at IS the destination, which is why the sidebar and the mode strip have
// to agree at all times.
function destination()
{
    if (state.dm)
        return { mode: "dm", name: state.dm };
    return { mode: "room", name: state.room ?? state.teamRoom };
}

function renderComposeMode()
{
    const { mode, name } = destination();
    el.composeMode.className = mode === "dm" ? "compose-mode dm" : "compose-mode";
    el.composeMode.innerHTML = mode === "dm"
        ? `direct to <strong>${esc(displayName(name))}</strong> — only ${esc(displayName(name))} sees this.<button type="button" id="compose-mode-exit">send to #general instead</button>`
        : `to <strong>#${esc(name)}</strong> — everyone in the room sees this`;
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

function renderDocs(payload)
{
    state.standDown = payload.standDown;
    el.standDown.textContent = payload.standDown ? "resume" : "stand down";
    el.standDown.className = payload.standDown ? "" : "danger";
    el.standDownBanner.hidden = !payload.standDown;

    // Which build is live is a fact cet can glance at, not something inferred
    // from a PID. Stale code shows up as a build hash that never changes.
    if (payload.build)
    {
        el.build.textContent = `build ${payload.build}`;
        el.build.title = `server build ${payload.build} · started ${payload.startedAt ? new Date(payload.startedAt).toLocaleTimeString() : "?"}`;
    }

    state.recess = payload.recess ?? { active: false };
    el.recess.textContent = state.recess.active ? "recess open" : "call recess";
    el.recess.className = state.recess.active ? "recess on" : "recess";
    el.recessBanner.hidden = !state.recess.active;
    el.recessWhen.textContent = state.recess.active
        ? `called by ${state.recess.by}${state.recess.note ? `: ${state.recess.note}` : ""}`
        : "";
}

function absorb(payload)
{
    state.human = payload.human;
    state.project = payload.project ?? state.project;
    state.teamRoom = payload.teamRoom;
    state.rooms = payload.rooms;
    state.agents = payload.agents;
    document.title = `${state.project} team room`;
    if (!state.room && !state.dm)
        state.room = state.teamRoom;
    renderSidebar();
    renderDocs(payload);
}

async function refresh()
{
    const payload = await fetch("/api/state").then((r) => r.json());
    absorb(payload);
    const known = new Set(state.messages.map((m) => m.id));
    for (const message of payload.messages)
        if (!known.has(message.id))
            state.messages.push(message);
    state.messages.sort((a, b) => a.ts - b.ts);
    renderMessages();
    markSeen();
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
    localStorage.setItem("coord-chat-seen", JSON.stringify(state.seen));
}

let sseUp = false;
let source = null;
// The server pings every 15s, so a stream that has shown no frame at all in
// 45s is silently dead — the browser's EventSource never reports a half-open
// connection as an error. The watchdog below forces a real reconnect.
let lastFrame = 0;
const FRAME_STALE_MS = 45_000;

function connect()
{
    source?.close();
    source = new EventSource("/api/stream");
    source.onopen = () =>
    {
        sseUp = true;
        lastFrame = Date.now();
        el.conn.textContent = "live";
        el.conn.className = "conn live";
        // Catch anything (rooms, docs, agents) that changed while we were down.
        refresh().catch(() => { });
    };
    source.onerror = () =>
    {
        sseUp = false;
        el.conn.textContent = "reconnecting…";
        el.conn.className = "conn dead";
    };
    source.onmessage = (event) =>
    {
        lastFrame = Date.now();
        const payload = JSON.parse(event.data);
        if (payload.type === "message")
        {
            if (!state.messages.some((m) => m.id === payload.entry.id))
            {
                state.messages.push(payload.entry);
                state.messages.sort((a, b) => a.ts - b.ts);
                renderMessages();
                markSeen();
                renderSidebar();
                if (payload.entry.from !== state.human && payload.entry.stream === "room")
                    flash();
            }
        }
        else if (payload.type === "standdown" || payload.type === "recess")
            refresh().catch(() => { });
        // "ping" and "hello" only prove the stream is alive — lastFrame is
        // already updated, nothing else to do.
    };
}

setInterval(() =>
{
    if (sseUp && Date.now() - lastFrame > FRAME_STALE_MS)
    {
        sseUp = false;
        connect();
    }
}, 10_000);

// Waking the tab is the other moment the view can be stale: whatever the
// stream missed while the page was frozen is picked up here.
document.addEventListener("visibilitychange", () =>
{
    if (document.visibilityState === "visible")
        refresh().catch(() => { });
});

let flashed = false;
function flash()
{
    if (flashed)
        return;
    flashed = true;
    document.title = `* ${state.project} team room`;
    setTimeout(() => { flashed = false; document.title = `${state.project} team room`; }, 2000);
}

async function send()
{
    const text = el.text.value.trim();
    if (!text)
        return;
    const { mode, name } = destination();
    el.text.value = "";
    el.hint.textContent = "sending…";
    try
    {
        const response = mode === "dm"
            ? await fetch("/api/dm", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ to: name, text }) })
            : await fetch("/api/say", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ room: name, text, kind: el.kind.value }),
            });
        const payload = await response.json();
        if (!payload.ok)
            throw new Error(payload.error ?? "send failed");
        el.hint.textContent = "";
        closeMentions();
        if (payload.pinged?.length)
            toast(`pinged ${payload.pinged.map((name) => `@${name}`).join(", ")} — delivered to their inbox`, "good");
    }
    catch (err)
    {
        el.hint.textContent = `not sent: ${err.message}`;
        toast(`not sent: ${err.message}`, "bad");
        el.text.value = text;
    }
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
    el.mentions.innerHTML = mentionState.items.map((item, index) =>
        `<li data-name="${esc(item.name)}" class="${index === mentionState.active ? "active" : ""}">
            <span class="who" style="color:${seatColor(item.name)}">@${esc(item.name)}</span>
            <span class="meta">${esc(item.role)}</span>
        </li>`).join("");
}

// The @token the caret is sitting in, if any. The @ has to start a word, so
// `user@host` does not open the list.
function mentionQuery()
{
    const caret = el.text.selectionStart;
    const match = /(^|[\s(])@([A-Za-z0-9_-]*)$/.exec(el.text.value.slice(0, caret));
    if (!match)
        return null;
    return { query: match[2].toLowerCase(), start: caret - match[2].length - 1 };
}

function updateMentions()
{
    const found = mentionQuery();
    const items = found
        ? mentionCandidates().filter((item) => item.name.toLowerCase().startsWith(found.query))
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
    el.text.value = `${before}@${item.name} ${after}`;
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

// Clicking a seat in the Direct list opens the 1:1; the old Seats sidebar list
// was removed as a third copy of the same information (Direct + header chips).

el.composeMode.addEventListener("click", (event) =>
{
    if (!event.target.closest("#compose-mode-exit"))
        return;
    state.dm = null;
    state.room = state.rooms.some((room) => room.name === state.teamRoom) ? state.teamRoom : (state.rooms[0]?.name ?? null);
    renderSidebar();
    renderMessages();
});

el.search.addEventListener("input", renderMessages);

async function recess(action, note)
{
    el.hint.textContent = "";
    try
    {
        const response = await fetch("/api/recess", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ action, note }),
        });
        const payload = await response.json();
        if (!payload.ok)
        {
            toast(`recess: ${payload.error}`, "bad");
            return;
        }
        toast(action === "end"
            ? "recess closed — the outcome is in #general"
            : "recess open — every seat has been asked to stop and talk", "good");
        refresh().catch(() => { });
    }
    catch (err)
    {
        toast(`recess failed: ${err.message}`, "bad");
    }
}

let recessEnding = false;

function openRecessDialog(ending)
{
    recessEnding = ending;
    el.recessDialogTitle.textContent = ending ? "close the recess" : "call recess";
    el.recessDialogLede.textContent = ending
        ? "What did the recess decide? It is posted to #general, and it is what the seats read as the outcome."
        : "Everything stops: every seat is asked to say who they are, what they are holding, and what they want to argue about. The note is posted to #general.";
    el.recessNote.value = "";
    el.recessNote.placeholder = ending ? "the decision" : "why the team is stopping (optional)";
    el.recessConfirm.textContent = ending ? "close recess" : "call recess";
    el.recessDialog.showModal();
    el.recessNote.focus();
}

el.recess.addEventListener("click", () => openRecessDialog(state.recess.active));

el.recessEnd.addEventListener("click", () => openRecessDialog(true));

el.recessCancel.addEventListener("click", () => el.recessDialog.close());

el.recessConfirm.addEventListener("click", () =>
{
    const note = el.recessNote.value.trim();
    el.recessDialog.close();
    recess(recessEnding ? "end" : "start", note);
});

el.standDown.addEventListener("click", async () =>
{
    const response = await fetch("/api/standdown", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ active: !state.standDown }),
    });
    const payload = await response.json();
    if (payload.ok)
        refresh().catch(() => { });
});

refresh().catch((err) =>
{
    el.conn.textContent = `offline (${err.message})`;
    el.conn.className = "conn dead";
});
connect();
// The stream pushes messages while it is up; the poll is only a recovery path
// for when it is down, so it does not double every refresh (or flood the console
// with connection errors while the server is gone).
setInterval(() =>
{
    if (!sseUp)
        refresh().catch(() => { });
}, 15_000);
