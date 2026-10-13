import { isFullDocument, overlayItems, pageHtml } from "../../content";

import assert from "node:assert/strict";
import { test } from "node:test";

const native = [
    { id: "automations", label: "Automations", path: "/automations", icon: "IconClock" },
    { id: "security", label: "Security", path: "/security", icon: "IconShield" },
];

test("native navigation is preserved without an enabled overlay", () =>
{
    assert.equal(overlayItems(native, { enabled: false, items: [], tabs: {} }), native);
});

test("sidebar overlay renames, removes and adds without changing native inputs", () =>
{
    const ret = overlayItems(native, {
        enabled: true,
        items: [
            { id: "automations", label: "Schedules", tab: "schedules" },
            { id: "security", hidden: true },
            { id: "events", label: "Events", tab: "events", icon: "IconBell" },
        ],
        tabs: { schedules: { title: "Schedules", html: "" }, events: { title: "Events", html: "" } },
    });
    assert.deepEqual(ret.map((item) => item.label), ["Schedules", "Events"]);
    assert.equal(ret[0]?.path, "/autonom/schedules");
    assert.equal(ret[1]?.icon, "IconBell");
    assert.equal(native[0]?.label, "Automations");
    assert.equal(native.length, 2);
});

test("a new sidebar item without a tab is rejected", () =>
{
    assert.throws(() => overlayItems(native, {
        enabled: true,
        items: [{ id: "orphan", label: "Orphan" }],
        tabs: {},
    }), /needs a tab/);
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

test("full documents are recognized so their own CSP applies", () =>
{
    assert.equal(isFullDocument("<!DOCTYPE html><html></html>"), true);
    assert.equal(isFullDocument("  <html lang=\"en\">"), true);
    assert.equal(isFullDocument("<h1>Fragment</h1>"), false);
});
