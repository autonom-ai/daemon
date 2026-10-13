import { loadCenter } from "../../center";

import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";

async function center(files: Record<string, string>, config: unknown): Promise<string>
{
    const directory = await mkdtemp(join(tmpdir(), "autonom-center-"));
    for (const [name, content] of Object.entries(files))
    {
        await mkdir(join(directory, name, ".."), { recursive: true });
        await writeFile(join(directory, name), content);
    }
    await writeFile(join(directory, "commandCenter.json"), JSON.stringify(config));
    return join(directory, "commandCenter.json");
}

test("a file-backed configuration loads every page and reports a revision", async () =>
{
    const path = await center({ "pages/events.html": "<h1>Events</h1>" }, {
        enabled: true,
        items: [{ id: "events", label: "Events", tab: "events" }],
        tabs: { events: { title: "Events", file: "pages/events.html" } },
        activeTab: "events",
    });
    try
    {
        const content = await loadCenter(path);
        assert.equal(content.enabled, true);
        assert.equal(content.activeTab, "events");
        assert.equal(content.tabs.events?.html, "<h1>Events</h1>");
        assert.match(content.revision ?? "", /^[a-f0-9]{64}$/);
        assert.equal((await loadCenter(path)).revision, content.revision);
    }
    finally
    {
        await rm(path, { force: true, recursive: true });
    }
});

test("invalid configurations are rejected as a whole", async () =>
{
    const cases: Record<string, unknown> = {
        "unknown tab reference": {
            enabled: true,
            items: [{ id: "events", tab: "missing" }],
            tabs: { events: { title: "Events", file: "pages/events.html" } },
        },
        "duplicate sidebar item": {
            enabled: true,
            items: [{ id: "events", tab: "events" }, { id: "events", tab: "events" }],
            tabs: { events: { title: "Events", file: "pages/events.html" } },
        },
        "hidden active tab": {
            enabled: true,
            items: [{ id: "events", tab: "events", hidden: true }],
            tabs: { events: { title: "Events", file: "pages/events.html" } },
            activeTab: "events",
        },
        "unsupported icon": {
            enabled: true,
            items: [{ id: "events", tab: "events", icon: "Icon Bad" }],
            tabs: { events: { title: "Events", file: "pages/events.html" } },
        },
    };
    for (const [name, config] of Object.entries(cases))
    {
        const path = await center({ "pages/events.html": "<h1>Events</h1>" }, config);
        await assert.rejects(loadCenter(path), Error, name);
        await rm(path, { force: true, recursive: true });
    }
});

test("page files must stay inside the configuration directory", async () =>
{
    const outside = await mkdtemp(join(tmpdir(), "autonom-outside-"));
    await writeFile(join(outside, "outside.html"), "<h1>Outside</h1>");
    const path = await center({ "pages/events.html": "<h1>Events</h1>" }, {
        enabled: true,
        items: [{ id: "events", tab: "events" }],
        tabs: { events: { title: "Events", file: "../outside.html" } },
    });
    try
    {
        await assert.rejects(loadCenter(path), /stay inside the configuration directory/);
    }
    finally
    {
        await rm(path, { force: true, recursive: true });
        await rm(outside, { force: true, recursive: true });
    }
});

test("symlinked page files are rejected", async () =>
{
    const path = await center({ "real.html": "<h1>Real</h1>" }, {
        enabled: true,
        items: [{ id: "events", tab: "events" }],
        tabs: { events: { title: "Events", file: "linked.html" } },
    });
    try
    {
        await symlink(join(dirname(path), "real.html"), join(dirname(path), "linked.html"));
        await assert.rejects(loadCenter(path), /ELOOP|symbolic|bounded regular file/);
    }
    finally
    {
        await rm(path, { force: true, recursive: true });
    }
});

test("oversized page files are rejected", async () =>
{
    const path = await center({ "pages/events.html": "x".repeat(262145) }, {
        enabled: true,
        items: [{ id: "events", tab: "events" }],
        tabs: { events: { title: "Events", file: "pages/events.html" } },
    });
    try
    {
        await assert.rejects(loadCenter(path), /bounded regular file/);
    }
    finally
    {
        await rm(path, { force: true, recursive: true });
    }
});
