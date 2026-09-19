// Team chat client. No framework: one stream, one list, one composer.

const state = {
    messages: [],
    rooms: [],
    agents: [],
    seen: JSON.parse(localStorage.getItem("coord-chat-seen") ?? "{}"),
    room: null,
    dm: null,
    human: "user",
    project: "team",
    teamRoom: "general",
    standDown: false,
    recess: { active: false },
};

const el = {
    rooms: document.getElementById("rooms"),
    dms: document.getElementById("dms"),
    messages: document.getElementById("messages"),
    count: document.getElementById("count"),
    conn: document.getElementById("conn"),
    build: document.getElementById("build"),
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

// The seats that can be pinged, plus @everyone. The human is excluded:
// pinging yourself is not a ping. Display names ping too (@ada hits ada), and
// #room pings every member of that room.
function mentionCandidates(sigil)
{
    if (sigil === "#")
        return state.rooms.map((room) => ({ name: room.name, role: `every member of #${room.name}` }));
    const ret = [{ name: "everyone", role: "every seat in the room" }];
    for (const agent of state.agents)
        if (agent.id !== state.human)
        {
            ret.push({ name: agent.id, role: displayName(agent.id) });
            const display = displayName(agent.id);
            if (display.toLowerCase() !== agent.id.toLowerCase())
                ret.push({ name: display, role: `display name of ${agent.id}` });
        }
    return ret;
}

// display name (lowercase) → seat id, mirroring the server's ping resolution.
function displayAliases()
{
    const ret = new Map();
    for (const agent of state.agents)
    {
        const display = displayName(agent.id);
        if (display.toLowerCase() !== agent.id.toLowerCase())
            ret.set(display.toLowerCase(), agent.id);
    }
    return ret;
}

function knownMentions()
{
    return new Set(["everyone", ...state.agents.map((agent) => agent.id)]);
}

// A ping is a room message that names the human or everyone. This is the "priority #1"
// rule made visible: such a message is marked in the log rather than left to look
// like ordinary chatter.
function isPing(message)
{
    if (message.stream !== "room")
        return false;
    const aliases = displayAliases();
    const me = state.human.toLowerCase();
    for (const match of (message.text ?? "").matchAll(/@([A-Za-z0-9_-]+)/g))
    {
        const name = match[1].toLowerCase();
        if (name === "everyone" || name === "all" || name === me || aliases.get(name) === state.human)
            return true;
    }
    // #room pings its members — the human is in every room the server seeded.
    for (const match of (message.text ?? "").matchAll(/#([A-Za-z0-9_-]+)/g))
        if (state.rooms.some((room) => room.name === match[1] && room.members.includes(state.human)))
            return true;
    return false;
}

// A ping DM is notification machinery, not conversation — "[PING]" fanout
// mirrors exist to wake a seat's inbox (the room message is the readable
// artifact), and "PING:" is the echo form from the ping tool. Both hide from
// the DM view and its unread count. Deliberately distinct from isPing(),
// which marks room messages that mention the human.
function isPingMirror(message)
{
    const text = message.text ?? "";
    return message.stream === "dm" && (text.startsWith("[PING]") || text.startsWith("PING:"));
}

function esc(text)
{
    return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

// The display name for a seat: the role/displayName if set, otherwise the raw id.
function displayName(id)
{
    const agent = state.agents.find((a) => a.id === id);
    const role = agent?.role;
    if (typeof role === "string" && role)
        return role;
    if (typeof role === "object" && role?.displayName)
        return role.displayName;
    return id;
}

// A stable muted color per seat — deterministic, so a seat keeps its color
// across workspaces and no per-project name list is needed. The human gets
// the accent-warm --human tone rather than a palette entry.
const SEAT_COLORS = ["#6d9ce8", "#5ec9a0", "#b78fe0", "#d99a55", "#5fc4cb", "#d9899e", "#a3bb6a", "#8f9ede"];
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
    const aliases = displayAliases();
    const me = state.human.toLowerCase();
    return esc(text)
        .replace(/`([^`\n]+)`/g, "<code>$1</code>")
        .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
        .replace(/(https?:\/\/[^\s<)&"'`]+[^\s<).,;:!?"'`])/g, '<a href="$1" target="_blank" rel="noopener">$1</a>')
        .replace(/([@#])([A-Za-z0-9_-]+)/g, (full, sigil, name) =>
        {
            if (sigil === "#")
            {
                if (!state.rooms.some((room) => room.name === name))
                    return full;
                return `<span class="mention">#${esc(name)}</span>`;
            }
            const lower = name.toLowerCase();
            const isMe = lower === me || aliases.get(lower) === state.human;
            if (!known.has(name) && !aliases.has(lower) && !isMe)
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
// your own send); "auto" follows only when the view is already at the
// bottom, so reading backscroll never gets yanked; anything else leaves
// the scroll position alone.
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
        // room, or long time gap ends the run even from the same sender — a
        // message an hour later is a new thought, not a continuation, and
        // hiding the name on it just reads as a blank author. A kind badge on
        // a merged message keeps a slim meta row so the badge is not hidden.
        const merged = prev !== null
            && prev.from === m.from
            && prev.stream === m.stream
            && (prev.room ?? null) === (m.room ?? null)
            && m.ts - prev.ts < 5 * 60_000
            && !isPing(m);
        prev = m;
        // DMs render only inside their own conversation view, so a "dm → x"
        // tag restates the view itself — room tags stay for the all-rooms view.
        const tag = m.stream === "room" && !state.room ? `<span class="tag">#${esc(m.room ?? "")}</span>` : "";
        const badge = m.kind ? `<span class="badge ${esc(m.kind)}">${esc(m.kind)}</span>` : "";
        const ping = isPing(m) ? "ping" : "";
        const meta = merged
            ? (badge || tag ? `<div class="meta">${badge}${tag}</div>` : "")
            : `<div class="meta"><span class="who" style="color:${seatColor(m.from)}">${esc(displayName(m.from))}</span>${badge}${tag}</div>`;
        return `<li class="msg ${m.stream === "dm" ? "dm" : ""} ${ping} ${mine ? "me" : ""} ${merged ? "merged" : ""}" data-id="${esc(m.id ?? "")}">
            <span class="when" title="${new Date(m.ts).toLocaleString()}">${clock(m.ts)}</span>
            <div class="body">
                ${meta}
                <div class="text">${renderText(m.text ?? "")}</div>
            </div>
        </li>`;
    }).join("");
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
        ? `Direct to ${displayName(name)} — only they see it. Enter sends, shift+enter for a newline.`
        : `To #${name} — enter sends, shift+enter for a newline. @ pings a seat or display name, # pings a room.`;
}

// A seat is as alive as its last bus touch — a message it sent or a read
// cursor its coord server moved. Thirty silent minutes means gone: it sinks
// out of the list entirely unless it left unread pings (those dim instead).
// The list doubles as the DM target picker, so a hidden seat cannot be
// written to at all — hiding is a reachability claim, not just decluttering.
// Your own seat is excluded for the same reason: you cannot DM yourself.
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
            <span class="name" style="color:${seatColor(agent.id)}">${esc(displayName(agent.id))}</span>
            <span class="meta">${unread ? `${unread} unread` : "1:1"}</span>
        </li>`;
    }).join("");
}

// Where the next message goes. There is no destination control: the view you are
// looking at IS the destination, which is why the sidebar and the composer
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

function renderDocs(payload)
{
    state.standDown = payload.standDown;
    el.standDown.textContent = payload.standDown ? "resume" : "stand down";
    el.standDown.className = payload.standDown ? "" : "danger";
    el.standDownBanner.hidden = !payload.standDown;

    // Which build is live is a fact the user can glance at, not something inferred
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
                // Only scroll for a message the current view actually shows —
                // traffic in another room shouldn't yank the scroll position.
                // Your own sends snap to bottom unconditionally; anything
                // else follows only when you're already there.
                renderMessages(visible(payload.entry)
                    ? (payload.entry.from === state.human ? "force" : "auto")
                    : "none");
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
    const sigil = mentionState.sigil ?? "@";
    el.mentions.innerHTML = mentionState.items.map((item, index) =>
        `<li data-name="${esc(item.name)}" class="${index === mentionState.active ? "active" : ""}">
            <span class="who" style="color:${sigil === "#" ? "var(--accent)" : seatColor(item.name)}">${sigil}${esc(item.name)}</span>
            <span class="meta">${esc(item.role)}</span>
        </li>`).join("");
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

// Clicking a seat in the Direct list opens the 1:1; the old Seats sidebar list
// was removed as a third copy of the same information (Direct + header chips).

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
