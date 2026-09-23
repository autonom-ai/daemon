// The extension host's view of one workspace's bus.
//
// CommonJS on purpose: the extension host loads `main` as CJS, and the bus
// modules it needs (agent-coord-mcp's store, core/chat/actions.mjs) are ESM, so
// they come in through dynamic import(). Everything the old HTTP server did —
// offsets, mention fanout, presence — lives here or in actions.mjs; the
// webview is presentation only.

const { existsSync, readFileSync, statSync } = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const importEsm = (file) => import(pathToFileURL(file).href);

async function loadStore(coordRoot)
{
    const storePath = [
        process.env.AGENT_COORD_STORE,
        path.join(coordRoot, "node_modules", "agent-coord-mcp", "dist", "store.js"),
    ].filter(Boolean).find((file) => existsSync(file));
    if (!storePath)
        throw new Error(`agent-coord-mcp store.js not found under ${coordRoot} — run \`npm ci --ignore-scripts\` in the clone`);
    return importEsm(storePath);
}

function readJson(file, fallback)
{
    try
    {
        return JSON.parse(readFileSync(file, "utf8"));
    }
    catch
    {
        return fallback;
    }
}

// displayName + color from agents/<id>/identity.md — the room renders people by
// who they are, not by bus id. Parsed here rather than importing the hooks'
// coord.mjs, which computes workspace config at import time.
function identityMeta(coordRoot, id)
{
    let raw = "";
    try
    {
        raw = readFileSync(path.join(coordRoot, "agents", id, "identity.md"), "utf8");
    }
    catch
    {
        return { display: id, color: null };
    }
    const front = /^---\n([\s\S]*?)\n---/.exec(raw);
    const meta = {};
    if (front)
        for (const line of front[1].split("\n"))
        {
            const match = /^(\w[\w-]*):\s*(.*)$/.exec(line.trim());
            if (match)
                meta[match[1]] = match[2];
        }
    const color = (meta.color ?? "").trim().replace(/^["']|["']$/g, "");
    return {
        display: meta.displayName?.trim() || id,
        color: color && color !== "null" ? color : null,
    };
}

async function openBus({ projectDir, coordRoot })
{
    const config = readJson(path.join(projectDir, ".devin", "coord.json"), {});
    const coordDir = path.join(projectDir, ".devin", "agent-coord", "state");
    process.env.AGENT_COORD_DIR = coordDir;
    const store = await loadStore(coordRoot);
    const actions = await importEsm(path.join(coordRoot, "core", "chat", "actions.mjs"));

    const ctx = {
        store,
        coordDir,
        project: config.project ?? path.basename(projectDir),
        teamRoom: config.teamRoom ?? "general",
        human: config.human ?? process.env.USER ?? "user",
    };

    // ---------- pump state ----------

    const offsets = new Map();
    const pending = new Map();
    const activity = new Map();
    let seeded = false;

    // One pass over the bus so a fresh extension does not blank every agent's
    // presence until their next message.
    function seedActivity()
    {
        for (const file of actions.watchedFiles(ctx))
        {
            let text;
            try
            {
                text = readFileSync(file, "utf8");
            }
            catch
            {
                continue;
            }
            for (const line of text.split("\n"))
            {
                if (!line.trim())
                    continue;
                try
                {
                    const entry = JSON.parse(line);
                    if (entry.from && entry.ts > (activity.get(entry.from) ?? 0))
                        activity.set(entry.from, entry.ts);
                }
                catch { }
            }
        }
    }

    // Returns the entries appended since the last call, in file order.
    function pump()
    {
        const fresh = [];
        for (const file of actions.watchedFiles(ctx))
        {
            let size = 0;
            try
            {
                size = statSync(file).size;
            }
            catch
            {
                continue;
            }
            if (!offsets.has(file))
            {
                // First sight during the open pass: history comes from state(),
                // not the stream. A file that appears AFTER the open pass — a
                // room created by its first message, the human's inbox — is new
                // content, so it is read from the top instead of swallowed.
                offsets.set(file, seeded ? 0 : size);
                if (!seeded)
                    continue;
            }
            const start = offsets.get(file);
            if (size < start)
            {
                offsets.set(file, 0); // the room compacted under us; re-read from the top
                pending.set(file, "");
                continue;
            }
            if (size === start)
                continue;
            let chunk;
            try
            {
                chunk = readFileSync(file).subarray(start).toString("utf8");
            }
            catch
            {
                continue;
            }
            offsets.set(file, size);
            const text = (pending.get(file) ?? "") + chunk;
            const lines = text.split("\n");
            pending.set(file, lines.pop() ?? "");
            for (const line of lines)
            {
                if (!line.trim())
                    continue;
                let entry;
                try
                {
                    entry = JSON.parse(line);
                }
                catch
                {
                    continue;
                }
                if (entry.from && entry.ts > (activity.get(entry.from) ?? 0))
                    activity.set(entry.from, entry.ts);
                const decorated = actions.decorate(entry, file, ctx);
                // Agent-authored room lines never went through say(), so the
                // mention fanout that lands pings in inboxes has to happen
                // here. The freshness guard keeps a post-compaction rescan
                // (offsets reset to 0) from re-pinging every mention.
                if (decorated.stream === "room" && decorated.from && decorated.from !== ctx.human
                    && decorated.ts > Date.now() - 60_000)
                    actions.fanoutMentions(ctx, decorated.room, decorated.text ?? "", decorated.from)
                        .catch((err) => console.error(`agent mention fanout failed: ${err?.message ?? err}`));
                fresh.push(decorated);
            }
        }
        seeded = true;
        return fresh;
    }

    // ---------- views ----------

    async function state()
    {
        return {
            project: ctx.project,
            human: ctx.human,
            teamRoom: ctx.teamRoom,
            agents: actions.registryView({ ...ctx, activity }).map((agent) => ({ ...agent, ...identityMeta(coordRoot, agent.id) })),
            rooms: await actions.roomList(ctx),
            messages: await actions.history(ctx, 400),
        };
    }

    // ---------- writes ----------

    async function say(room, text, kind, inReplyTo)
    {
        return actions.say(ctx, room, text, kind, inReplyTo);
    }

    async function sendDm(to, text, inReplyTo)
    {
        return actions.dm(ctx, to, text, inReplyTo);
    }

    seedActivity();
    // Establish the pump's file offsets at open time, before anything can be
    // written: history is state()'s job, and a message that lands while the
    // extension is still starting must not be swallowed as first-sight history.
    pump();
    await actions.registerHuman(ctx);
    return {
        ctx,
        projectDir,
        coordRoot,
        state,
        pump,
        say,
        sendDm,
        heartbeat: () => actions.touchHeartbeat(ctx),
    };
}

module.exports = { openBus, readJson };
