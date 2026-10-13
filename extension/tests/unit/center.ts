import { loadCenter, overlayItems, pageHtml } from "../../source/host/center";

import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const native = [
    { id: "automations", label: "Automations", path: "/automations", icon: "IconClock" },
    { id: "security", label: "Security", path: "/security", icon: "IconShield" },
];

test("native navigation is preserved without an enabled overlay", () => {
    assert.equal(overlayItems(native, { enabled: false, items: [], tabs: {} }), native);
});

test("sidebar overlay renames, removes and adds without changing native inputs", () => {
    const ret = overlayItems(native, {
        enabled: true,
        items: [
            { id: "automations", label: "Jared", tab: "hello" },
            { id: "security", hidden: true },
            { id: "notes", label: "Notes", tab: "hello", icon: "IconBookOpen" },
        ],
        tabs: { hello: { title: "Hello", html: "Hello world" } },
    });
    assert.deepEqual(ret.map((item) => item.label), ["Jared", "Notes"]);
    assert.equal(ret[0]?.path, "/autonom/hello");
    assert.equal(native[0]?.label, "Automations");
    assert.equal(native.length, 2);
});

test("custom pages receive a restrictive CSP and no host capability", () => {
    const ret = pageHtml({ title: "Hello <world>", html: "<h1>Hello world</h1>" });
    assert.ok(ret.includes("<h1>Hello world</h1>"));
    assert.ok(ret.includes("script-src 'none'"));
    assert.ok(ret.includes("connect-src 'none'"));
    assert.ok(ret.includes("Hello &lt;world&gt;"));
    assert.ok(!ret.includes("acquireVsCodeApi"));
});

test("file-backed configuration reloads content and validates the entire replacement", async () => {
    const directory = await mkdtemp(join(tmpdir(), "autonom-center-"));
    const configDirectory = join(directory, ".devin");
    const config = join(configDirectory, "commandCenter.json");
    const text = JSON.stringify({
        enabled: true,
        items: [{ id: "automations", label: "Jared", tab: "hello" }],
        tabs: { hello: { title: "Hello", file: "hello.html" } },
        activeTab: "hello",
    });
    try {
        await mkdir(configDirectory);
        await writeFile(config, text);
        await writeFile(join(configDirectory, "hello.html"), "<h1>Hello world</h1>");
        const first = await loadCenter(config);
        assert.equal(first.tabs.hello?.html, "<h1>Hello world</h1>");
        await writeFile(join(configDirectory, "hello.html"), "<h1>Edited live</h1>");
        const second = await loadCenter(config);
        assert.notEqual(first.revision, second.revision);
        assert.equal(second.tabs.hello?.html, "<h1>Edited live</h1>");
        assert.equal(await readFile(config, "utf8"), text);
        await writeFile(config, text.replace("hello.html", "../outside.html"));
        await assert.rejects(loadCenter(config), /inside the configuration directory/);
        await writeFile(config, text.replace('"tab":"hello"', '"tab":"missing"'));
        await assert.rejects(loadCenter(config), /Unknown tab/);
        await writeFile(config, text.replace('"activeTab":"hello"', '"activeTab":"missing"'));
        await assert.rejects(loadCenter(config), /Unknown active tab/);
        await writeFile(config, text.replace('"items":[', '"items":[{"id":"automations"},'));
        await assert.rejects(loadCenter(config), /Duplicate sidebar/);
        await writeFile(config, text);
        await symlink("hello.html", join(configDirectory, "linked.html"));
        await writeFile(config, text.replace("hello.html", "linked.html"));
        await assert.rejects(loadCenter(config));

        // Test autonom tab without file
        const autonomConfig = JSON.stringify({
            enabled: true,
            items: [{ id: "automations", label: "Command Center", tab: "autonom" }],
            tabs: { autonom: { title: "Command Center", autonom: true } },
            activeTab: "autonom",
        });
        await writeFile(config, autonomConfig);
        const loadedAutonom = await loadCenter(config);
        assert.equal(loadedAutonom.tabs.autonom?.title, "Command Center");
        assert.equal(loadedAutonom.tabs.autonom?.autonom, true);
        assert.equal(loadedAutonom.tabs.autonom?.html, "");
    } finally {
        await rm(directory, { recursive: true, force: true });
    }
});

test("autonomPageHtml wraps UI bundle with script-src inline, connect-src none and escapes title", async () => {
    const { autonomPageHtml } = await import("../../source/commandCenter/content.js");
    const html = autonomPageHtml(
        { title: "Autonom <Center>", html: "<div class=\"test\">Hello</div>" },
        "console.log('bundle');",
        ".test { color: red; }",
    );
    assert.ok(html.includes("<title>Autonom &lt;Center&gt;</title>"));
    assert.ok(html.includes("script-src 'unsafe-inline'"));
    assert.ok(html.includes("connect-src 'none'"));
    assert.ok(html.includes("console.log('bundle');"));
    assert.ok(html.includes(".test { color: red; }"));
    assert.ok(html.includes("<div id=\"app\"><div class=\"test\">Hello</div></div>"));
});
