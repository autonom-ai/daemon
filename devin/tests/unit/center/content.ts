import type { SidebarItem } from "../../../launcher/center/content";
import { isFullDocument, overlayItems, pageHtml } from "../../../launcher/center/content";

import assert from "node:assert/strict";
import { test } from "node:test";

const native = [
    { id: "automations", label: "Automations", path: "/automations", icon: "IconClock", native: true },
    { id: "security", label: "Security", path: "/security", icon: "IconShield", native: true },
];

function item(id: string, label: string): SidebarItem
{
    return { id, label, actions: { left_click: { type: "html", file: `pages/${id}.html`, version: "unit" } } };
}

test("disabled UI preserves the original native navigation", () =>
{
    assert.equal(overlayItems(native, { enabled: false, sections: [] }), native);
});

test("section and item order defines the navigation without changing native objects", () =>
{
    const ret = overlayItems(native, {
        enabled: true,
        sections: [
            { id: "first", items: [item("events", "Events"), { id: "hidden", hidden: true }] },
            { id: "second", items: [item("automations", "Schedules")] },
        ],
    });
    assert.deepEqual(ret.map((entry) => entry.label), ["Events", "Schedules"]);
    assert.equal(ret[0]?.path, "/autonom/events");
    assert.equal(ret[1]?.path, "/autonom/automations");
    assert.equal(ret[1]?.native, true);
    assert.equal(native[0]?.label, "Automations");
    assert.equal(native.length, 2);
});

test("flat items are not nested under empty sections", () =>
{
    const ret = overlayItems(native, {
        enabled: true,
        items: [item("events", "Events"), item("automations", "Schedules")],
        sections: [{ id: "rooms", label: "Rooms", items: [] }, { id: "profiles", label: "Profiles", items: [] }],
    });
    assert.deepEqual(ret.map((entry) => entry.id), ["events", "automations"]);
});

test("new items require an action; existing native items can retain their navigation", () =>
{
    assert.throws(() => overlayItems(native, {
        enabled: true,
        sections: [{ id: "group", items: [{ id: "orphan", label: "Orphan" }] }],
    }), /needs a left_click/);
    assert.equal(overlayItems(native, {
        enabled: true,
        devinCloud: ["security"],
        sections: [{ id: "group", items: [{ id: "security", label: "Policy" }] }],
    })[0]?.path, "/security");
});

test("native Cloud imports are YAML-selected, retain their routes, and never appear implicitly", () =>
{
    const nativeItems = [...native, { id: "wiki", label: "Wiki", icon: "wiki", path: "/wiki", native: true }];
    assert.deepEqual(overlayItems(nativeItems, { enabled: true, sections: [] }), []);
    assert.deepEqual(overlayItems(nativeItems, { enabled: true, sections: [], devinCloud: ["wiki"] }), [nativeItems[2]]);
    const imported = overlayItems(nativeItems, {
        enabled: true,
        devinCloud: ["security", "wiki"],
        sections: [{ id: "knowledge", items: [{ id: "wiki" }] }],
    });
    assert.deepEqual(imported.map((item) => item.path), ["/wiki", "/security"]);
    assert.throws(() => overlayItems(nativeItems, {
        enabled: true, sections: [], devinCloud: ["missing"],
    }), /Unknown Devin Cloud/);
});

test("fragment pages receive a restrictive CSP and no host capability", () =>
{
    const ret = pageHtml({ title: "Hello <world>", html: "<h1>Hello world</h1>" });
    assert.ok(ret.includes("<h1>Hello world</h1>"));
    assert.ok(ret.includes("script-src 'none'"));
    assert.ok(ret.includes("connect-src 'none'"));
    assert.ok(ret.includes("Hello &lt;world&gt;"));
    assert.ok(!ret.includes("acquireVsCodeApi"));
});

test("full documents keep their own CSP", () =>
{
    assert.equal(isFullDocument("<!DOCTYPE html><html></html>"), true);
    assert.equal(isFullDocument("  <html lang=\"en\">"), true);
    assert.equal(isFullDocument("<h1>Fragment</h1>"), false);
});
