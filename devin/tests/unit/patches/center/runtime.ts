import type { CenterContent } from "../../../../launcher/center/content";
import { install } from "../../../../launcher/patches/center/runtime";
import { config, fixture, testContent } from "../../../support";

import assert from "node:assert/strict";
import { after, beforeEach, test } from "node:test";

const originalFetch = globalThis.fetch;
let messages: Record<string, unknown>[] = [];
beforeEach(() =>
{
    messages = [];
    globalThis.fetch = async (_url, options) =>
    {
        const message = JSON.parse(String(options?.body));
        messages.push(message);
        return Response.json({ result: message.action === "getAction"
            ? { type: "html", source: "<h1>Hello world</h1>" } : null });
    };
});
after(() =>
{
    globalThis.fetch = originalFetch;
});

test("runtime reload is atomic and open tab uses native navigation", async () =>
{
    const environment = fixture();
    const runtime = install(environment.services, config());
    try
    {
        await runtime.update(config());
        await assert.rejects(runtime.update(config({
            enabled: true,
            sections: [{ id: "broken", items: [{ id: "unknown", label: "Broken" }] }],
        })), /needs a left_click/);
        assert.equal(runtime.status().items[0].label, "Jared");
        await runtime.open("automations");
        assert.equal(runtime.status().activeItem, "automations");
        assert.deepEqual(environment.commands, [{
            command: "devin.desktopNav.openSurface",
            surface: { id: "automations", path: "/autonom/automations" },
        }]);
        await assert.rejects(runtime.open("missing"), /Unknown, hidden/);
        await runtime.update(config({ enabled: false, sections: [] }));
        assert.equal(runtime.status().enabled, false);
        assert.equal(runtime.status().activeItem, null);
        assert.equal(environment.services.groups.getActiveNavSurface().path, "/automations");
        assert.equal(environment.services.manifest.getManifest(), environment.base);
    }
    finally
    {
        runtime.dispose();
    }
});

test("provider mode returns to native Devin navigation and switches back without a reload", async () =>
{
    const environment = fixture();
    const runtime = install(environment.services, config());
    try
    {
        await runtime.update(config());
        await runtime.open("automations");
        const cloud = await runtime.setMode("devin-cloud");
        assert.equal(cloud.mode, "devin-cloud");
        assert.equal(cloud.enabled, false);
        assert.equal(environment.services.manifest.getManifest(), environment.base);
        assert.equal(environment.services.groups.getActiveNavSurface().path, "/automations");
        const autonom = await runtime.setMode("autonom");
        assert.equal(autonom.mode, "autonom");
        assert.equal(autonom.enabled, true);
        assert.equal(autonom.activeItem, "automations");
        assert.equal(environment.commands.length, 3);
    }
    finally
    {
        runtime.dispose();
    }
});

test("revealing the Agent sidebar runs the native command only while it is hidden", async () =>
{
    const target = globalThis as any;
    const originalDocument = target.document;
    const environment = fixture();
    const runtime = install(environment.services, config());
    const revealWith = async (hidden: boolean): Promise<void> =>
    {
        target.document = {
            querySelector(selector: string): unknown
            {
                return selector === ".monaco-workbench" ? { classList: { contains: () => hidden } } : null;
            },
        };
        try
        {
            await runtime.revealAgentSidebar();
        }
        finally
        {
            if (originalDocument === undefined)
                delete target.document;
            else
                target.document = originalDocument;
        }
    };

    try
    {
        await runtime.update(config());
        await revealWith(true);
        assert.deepEqual(environment.commands, [{ command: "workbench.action.focusAuxiliaryBar", surface: undefined }]);
        await revealWith(false);
        assert.equal(environment.commands.length, 1);
        delete target.document;
        await runtime.revealAgentSidebar();
        assert.equal(environment.commands.length, 1);
    }
    finally
    {
        runtime.dispose();
        if (originalDocument === undefined)
            delete target.document;
        else
            target.document = originalDocument;
    }
});

test("HTML actions are lazy and repeated opens reuse the same source", async () =>
{
    const environment = fixture();
    const runtime = install(environment.services, config());
    try
    {
        await runtime.update(config());
        assert.equal(runtime.status().loadedActions, 0);
        assert.equal(messages.length, 0);
        await runtime.open("automations");
        await runtime.open("automations");
        assert.equal(messages.length, 1);
        assert.deepEqual(messages[0], { action: "getAction", id: "automations", revision: "demo", windowId: 2 });
        assert.equal(runtime.status().loadedActions, 1);
    }
    finally
    {
        runtime.dispose();
    }
});

test("JS actions do not navigate to a page and run with the scoped UI context", async () =>
{
    const environment = fixture();
    const content = { ...testContent, sections: [{ id: "tools", items: [{
        id: "run",
        actions: { left_click: { type: "js" as const, file: "run.js", version: "script-one" } },
    }] }] };
    const runtime = install(environment.services, config(content));
    try
    {
        await runtime.update(config(content));
        await runtime.activate("run");
        assert.equal(environment.commands.length, 0);
        assert.deepEqual(messages[0], { action: "runScript", id: "run", revision: "demo", windowId: 2 });
        let executions = 0;
        runtime.setScript("run", "script-one", async (context: any) =>
        {
            assert.ok(Object.isFrozen(context));
            assert.equal(context.item.id, "run");
            executions++;
            await context.executeCommand("native.action", { id: "native", path: "/native" });
        });
        assert.equal(runtime.hasScript("run", "script-one"), true);
        await runtime.runScript("run", "script-one");
        await runtime.runScript("run", "script-one");
        assert.equal(executions, 2);
        assert.equal(runtime.status().compiledScripts, 1);
        assert.equal(runtime.status().loadedActions, 1);
        assert.equal(environment.commands.length, 2);
        await runtime.update(config({ ...testContent, sections: [] }));
        assert.equal(runtime.status().compiledScripts, 0);
        await assert.rejects(runtime.runScript("run", "script-one"), /not available/);
    }
    finally
    {
        runtime.dispose();
    }
});

test("status reports section buttons and the reserved Spaces import", async () =>
{
    const environment = fixture();
    const content: CenterContent = {
        enabled: true,
        revision: "demo",
        devinCloud: ["spaces"],
        sections: [{ id: "rooms", label: "Rooms", items: [], buttons: [
            { id: "rooms-search", search: true },
            { id: "rooms-new", label: "New room",
                actions: { left_click: { type: "js", file: "new.js", version: "v1" } } },
            { id: "rooms-hidden", hidden: true },
        ] }],
    };
    const runtime = install(environment.services, config(content));
    try
    {
        const status = await runtime.update(config(content));
        assert.equal(status.spaces, true);
        assert.deepEqual(status.sections, [
            { id: "rooms", label: "Rooms", items: [], buttons: ["rooms-search", "rooms-new"] },
        ]);
        await assert.rejects(runtime.activate("rooms-search"), /Unknown or hidden/);
        await assert.rejects(runtime.activate("rooms-hidden"), /Unknown or hidden/);
        await runtime.activate("rooms-new");
        assert.deepEqual(messages[0], { action: "runScript", id: "rooms-new", revision: "demo", windowId: 2 });
        let section: unknown;
        runtime.setScript("rooms-new", "v1", async (context: any) =>
        {
            section = context.section;
        });
        await runtime.runScript("rooms-new", "v1");
        assert.deepEqual(section, { id: "rooms", label: "Rooms" });
        await runtime.update(config({ enabled: true, sections: [] }));
        assert.equal(runtime.status().spaces, false);
        await runtime.update(config({ enabled: false, sections: [] }));
        assert.equal(runtime.status().spaces, true);
    }
    finally
    {
        runtime.dispose();
    }
});

test("a failed lazy page refresh keeps the previous snapshot active", async () =>
{
    const environment = fixture();
    const runtime = install(environment.services, config());
    try
    {
        await runtime.update(config());
        await runtime.open("automations");
        globalThis.fetch = async () =>
        {
            throw new Error("unavailable");
        };
        const content = { ...testContent, revision: "next", sections: [{ id: "pages", items: [{
            id: "automations",
            label: "Changed",
            actions: { left_click: { type: "html" as const, file: "pages/welcome.html", version: "next" } },
        }] }] };
        await assert.rejects(runtime.update(config(content)), /unavailable/);
        assert.equal(runtime.status().revision, "demo");
        assert.equal(runtime.status().items[0].label, "Jared");
    }
    finally
    {
        runtime.dispose();
    }
});

test("the default HTML item is not opened or prefetched while Editor is selected", async () =>
{
    const target = globalThis as any;
    const originalShell = target.__autonomShell;
    target.__autonomShell = {
        editorActive: () => true,
        requestedMode: () => "autonom",
        dispose: () => undefined,
    };
    const environment = fixture();
    const runtime = install(environment.services, config({ ...testContent, activeItem: "automations" }));
    try
    {
        await runtime.update(config({ ...testContent, activeItem: "automations" }));
        assert.equal(runtime.status().activeItem, null);
        assert.equal(environment.commands.length, 0);
        assert.equal(messages.length, 0);
    }
    finally
    {
        runtime.dispose();
        if (originalShell)
            target.__autonomShell = originalShell;
        else
            delete target.__autonomShell;
    }
});
