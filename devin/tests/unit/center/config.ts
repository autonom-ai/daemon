import type { ActionCache } from "../../../launcher/center/config";
import { loadAction, loadCenter } from "../../../launcher/center/config";
import { declaredItems } from "../../../launcher/center/content";

import { stringify } from "yaml";

import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";

async function center(files: Record<string, string>, config: unknown): Promise<string>
{
    const directory = await mkdtemp(join(tmpdir(), "autonom-center-"));
    for (const [name, content] of Object.entries(files))
    {
        await mkdir(dirname(join(directory, name)), { recursive: true });
        await writeFile(join(directory, name), content);
    }

    await writeFile(join(directory, "ui.yml"), stringify(config));
    return join(directory, "ui.yml");
}

function definition(file = "pages/events.html"): unknown
{
    return {
        enabled: true,
        sections: [{ id: "coordination", label: "Coordination", items: [
            { id: "events", label: "Events", actions: { left_click: file } },
        ] }],
    };
}

test("YAML sections load metadata only, then read an action once on demand", async () =>
{
    const path = await center({ "pages/events.html": "<h1>Events</h1>", "ui.css": "h2{color:red}" }, definition());
    try
    {
        const content = await loadCenter(path);
        assert.equal(content.enabled, true);
        assert.equal(content.sections[0]?.label, "Coordination");
        const action = content.sections[0]?.items[0]?.actions?.left_click;
        assert.equal(action?.type, "html");
        assert.equal(action?.file, "pages/events.html");
        assert.ok(!JSON.stringify(content).includes("<h1>Events</h1>"));
        assert.equal(content.css, "h2{color:red}");
        assert.equal((await loadCenter(path)).revision, content.revision);
        const cache: ActionCache = new Map();
        const source = await loadAction(path, content, "events", content.revision!, cache);
        assert.deepEqual(source, { type: "html", source: "<h1>Events</h1>" });
        assert.equal(await loadAction(path, content, "events", content.revision!, cache), source);
        assert.equal(cache.size, 1);
        await assert.rejects(loadAction(path, content, "events", "stale", cache), /definition changed/);
        await assert.rejects(loadAction(path, content, "missing", content.revision!, cache), /Unknown or hidden/);
    }
    finally
    {
        await rm(dirname(path), { recursive: true, force: true });
    }
});

test("JS actions and empty sections are accepted without eagerly executing or reading scripts", async () =>
{
    const path = await center({ "run.js": "await context.open('events');" }, {
        sections: [
            { id: "empty", label: "Empty", items: [] },
            { id: "tools", items: [{ id: "run", actions: { left_click: "run.js" } }] },
        ],
    });
    try
    {
        const content = await loadCenter(path);
        assert.equal(content.sections.length, 2);
        assert.equal(content.sections[1]?.items[0]?.actions?.left_click.type, "js");
        assert.ok(!JSON.stringify(content).includes("context.open"));
        assert.equal((await loadAction(path, content, "run", content.revision!, new Map())).source,
            "await context.open('events');");
    }
    finally
    {
        await rm(dirname(path), { recursive: true, force: true });
    }
});

test("invalid YAML layouts and unsupported actions reject the entire definition", async () =>
{
    const item = { id: "events", actions: { left_click: "pages/events.html" } };
    const cases = [
        { sections: [{ id: "group", items: [item, item] }] },
        { sections: [{ id: "group", items: [] }, { id: "group", items: [] }] },
        { sections: [{ id: "group", items: [{ ...item, icon: "Icon Bad" }] }] },
        { sections: [{ id: "group", items: [{ ...item, actions: { right_click: "pages/events.html" } }] }] },
        { sections: [{ id: "group", items: [{ ...item, actions: { left_click: "page.txt" } }] }] },
        { sections: [{ id: "group", items: [{ ...item, actions: { left_click: "pages/events.html", right_click: "run.js" } }] }] },
        { sections: [{ id: "group", items: [{ ...item, hidden: true }] }], active_item: "events" },
        { sections: [{ id: "group", items: [item] }], active_item: "missing" },
        { sections: [{ id: "group", items: [{ ...item, tab: "old" }] }] },
        { sections: [], tabs: {} },
        { sections: [], items: "not a list" },
        { sections: [], enabled: "yes" },
        { sections: [{ id: "group", items: [{ id: "missing" }] }] },
    ];
    for (const config of cases)
    {
        const path = await center({ "pages/events.html": "<h1>Events</h1>" }, config);
        try
        {
            await assert.rejects(loadCenter(path));
        }
        finally
        {
            await rm(dirname(path), { recursive: true, force: true });
        }
    }

    const path = await center({}, { sections: [] });
    try
    {
        await writeFile(path, "sections: [broken\n");
        await assert.rejects(loadCenter(path), /invalid YAML/);
    }
    finally
    {
        await rm(dirname(path), { recursive: true, force: true });
    }
});

test("flat items precede empty Rooms and Profiles sections", async () =>
{
    const path = await center({ "pages/events.html": "<h1>Events</h1>" }, {
        items: [{ id: "events", actions: { left_click: "pages/events.html" } }],
        sections: [{ id: "rooms", label: "Rooms" }, { id: "profiles", label: "Profiles", items: [] }],
        active_item: "events",
    });
    try
    {
        const content = await loadCenter(path);
        assert.equal(content.items?.[0]?.id, "events");
        assert.deepEqual(content.sections, [
            { id: "rooms", label: "Rooms", items: [] },
            { id: "profiles", label: "Profiles", items: [] },
        ]);
        assert.equal(content.activeItem, "events");
        await writeFile(path, stringify({
            items: [{ id: "rooms", hidden: true }], sections: [{ id: "rooms", label: "Rooms" }],
        }));
        await assert.rejects(loadCenter(path), /Duplicate UI id/);
    }
    finally
    {
        await rm(dirname(path), { recursive: true, force: true });
    }
});

test("native Cloud import ids are validated and may be placed without custom actions", async () =>
{
    const path = await center({}, {
        devin_cloud: ["wiki", "review"],
        sections: [{ id: "native", items: [{ id: "wiki" }] }],
    });
    try
    {
        const content = await loadCenter(path);
        assert.deepEqual(content.devinCloud, ["wiki", "review"]);
        assert.equal(content.sections[0]?.items[0]?.actions, undefined);
        for (const devin_cloud of [["wiki", "wiki"], ["Bad Id"], "wiki"])
        {
            await writeFile(path, stringify({ devin_cloud, sections: [] }));
            await assert.rejects(loadCenter(path), /unique native/);
        }
    }
    finally
    {
        await rm(dirname(path), { recursive: true, force: true });
    }
});

test("the reserved spaces id imports the native Spaces section without an item", async () =>
{
    const path = await center({}, {
        devin_cloud: ["wiki", "spaces"],
        sections: [{ id: "native", items: [{ id: "wiki" }] }],
    });
    try
    {
        const content = await loadCenter(path);
        assert.deepEqual(content.devinCloud, ["wiki", "spaces"]);
        assert.deepEqual(declaredItems(content).map((item) => item.id), ["wiki"]);
        await writeFile(path, stringify({ devin_cloud: ["spaces", "spaces"], sections: [] }));
        await assert.rejects(loadCenter(path), /unique native/);
    }
    finally
    {
        await rm(dirname(path), { recursive: true, force: true });
    }
});

test("section buttons load validated js actions and resolve through loadAction", async () =>
{
    const path = await center({ "actions/new-room.js": "await context.open('rooms');" }, {
        sections: [{ id: "rooms", label: "Rooms", items: [], buttons: [
            { id: "rooms-search", search: true },
            { id: "rooms-new", label: "New room", icon: "plus", actions: { left_click: "actions/new-room.js" } },
            { id: "rooms-hidden", hidden: true },
        ] }],
    });
    try
    {
        const content = await loadCenter(path);
        assert.equal(content.sections[0]?.items.length, 0);
        const buttons = content.sections[0]?.buttons;
        assert.equal(buttons?.length, 3);
        assert.equal(buttons?.[0]?.search, true);
        assert.equal(buttons?.[1]?.actions?.left_click.type, "js");
        assert.equal(buttons?.[1]?.actions?.left_click.file, "actions/new-room.js");
        assert.equal(buttons?.[2]?.hidden, true);
        assert.ok(!JSON.stringify(content).includes("context.open"));
        assert.deepEqual(declaredItems(content).map((item) => item.id), ["rooms-new"]);
        const cache: ActionCache = new Map();
        const source = await loadAction(path, content, "rooms-new", content.revision!, cache);
        assert.deepEqual(source, { type: "js", source: "await context.open('rooms');" });
        assert.equal(await loadAction(path, content, "rooms-new", content.revision!, cache), source);
        await assert.rejects(loadAction(path, content, "rooms-search", content.revision!, cache), /Unknown or hidden/);
        await assert.rejects(loadAction(path, content, "rooms-hidden", content.revision!, cache), /Unknown or hidden/);
    }
    finally
    {
        await rm(dirname(path), { recursive: true, force: true });
    }
});

test("section buttons accept only bundled icon names", async () =>
{
    const path = await center({ "actions/open-settings.js": "await context.open('settings');" }, {
        sections: [{ id: "rooms", label: "Rooms", items: [], buttons: [
            { id: "rooms-properties", label: "Properties", icon: "settings-2",
                actions: { left_click: "actions/open-settings.js" } },
        ] }],
    });
    try
    {
        const content = await loadCenter(path);
        assert.equal(content.sections[0]?.buttons?.[0]?.icon, "settings-2");
    }
    finally
    {
        await rm(dirname(path), { recursive: true, force: true });
    }
});

test("the shipped definition loads with the sidebar marks in place", async () =>
{
    const content = await loadCenter(resolve(__dirname, "../../../../assets/ui.yml"));
    const properties = content.sections[0]?.buttons?.find((button) => button.id === "rooms-properties");
    assert.equal(properties?.icon, "settings-2");
    const settings = content.items?.find((item) => item.id === "settings");
    assert.equal(settings?.icon, "settings");
});

test("invalid section buttons reject the entire definition", async () =>
{
    const action = { left_click: "actions/new.js" };
    const page = { left_click: "pages/events.html" };
    const cases = [
        { sections: [{ id: "group", buttons: [{ id: "add", actions: action }] }] },
        { sections: [{ id: "group", label: "Group", buttons: "not a list" }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "Bad Id", search: true }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "add", label: "x".repeat(201), actions: action }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "add", icon: "IconPlus", actions: action }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "add", icon: "file", actions: action }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "add", icon: "sliders", actions: action }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "add", hidden: "yes", actions: action }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "find", search: "yes" }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "add", actions: action, tab: "old" }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "find", search: true, actions: action }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "add" }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "add", actions: page }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "add", hidden: true, actions: page }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "add", actions: { left_click: "actions/missing.js" } }] }] },
        { sections: [{ id: "group", label: "Group", buttons: [{ id: "group", search: true }] }] },
        { sections: [{ id: "group", label: "Group", items: [{ id: "add", actions: page }], buttons: [{ id: "add", actions: action }] }] },
        { items: [{ id: "add", actions: page }], sections: [{ id: "group", label: "Group", buttons: [{ id: "add", actions: action }] }] },
    ];
    for (const config of cases)
    {
        const path = await center({ "pages/events.html": "<h1>Events</h1>", "actions/new.js": "noop" }, config);
        try
        {
            await assert.rejects(loadCenter(path));
        }
        finally
        {
            await rm(dirname(path), { recursive: true, force: true });
        }
    }
});

test("action paths are confined, no-follow, bounded, and must exist", async () =>
{
    const path = await center({ "real.html": "<h1>Real</h1>", "large.html": "x".repeat(262145) }, definition());
    try
    {
        for (const file of ["../outside.html", "/tmp/outside.html", "missing.html", "large.html"])
        {
            await writeFile(path, stringify(definition(file)));
            await assert.rejects(loadCenter(path));
        }

        await symlink(join(dirname(path), "real.html"), join(dirname(path), "linked.html"));
        await writeFile(path, stringify(definition("linked.html")));
        await assert.rejects(loadCenter(path), /ELOOP|symbolic/);
    }
    finally
    {
        await rm(dirname(path), { recursive: true, force: true });
    }
});

test("editing an action changes its revision and invalidates only that cached file", async () =>
{
    const path = await center({ "pages/events.html": "<h1>Before</h1>" }, definition());
    try
    {
        const first = await loadCenter(path);
        const cache: ActionCache = new Map();
        await loadAction(path, first, "events", first.revision!, cache);
        await writeFile(join(dirname(path), "pages/events.html"), "<h1>After and longer</h1>");
        const next = await loadCenter(path);
        assert.notEqual(next.revision, first.revision);
        assert.equal((await loadAction(path, next, "events", next.revision!, cache)).source, "<h1>After and longer</h1>");
        assert.equal(cache.size, 1);
        await assert.rejects(loadAction(path, first, "events", first.revision!, new Map()), /file changed/);
    }
    finally
    {
        await rm(dirname(path), { recursive: true, force: true });
    }
});
