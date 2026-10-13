import { config, fixture } from "../support";
import { install } from "../../runtime";

import assert from "node:assert/strict";
import { test } from "node:test";

test("runtime caches immutable manifest overlays and restores exact descriptors", async () =>
{
    const environment = fixture();
    const manifest = environment.services.manifest;
    const controller = environment.services.controller;
    const originalManifest = Object.getOwnPropertyDescriptor(manifest, "getManifest");
    const originalShow = Object.getOwnPropertyDescriptor(controller, "show");
    const runtime = install(environment.services, config());
    try
    {
        assert.equal(manifest.getManifest(), environment.base);
        await runtime.update(config());
        const first = manifest.getManifest();
        assert.equal(first, manifest.getManifest());
        assert.equal(first.items[0].label, "Jared");
        assert.equal(environment.base.items[0].label, "Automations");
        assert.equal(environment.base.revision, "native");
        manifest._onDidChangeManifest.fire(environment.base);
        assert.equal(manifest.getManifest().items[0].label, "Jared");
        assert.equal(runtime.status().connected, true);
        assert.equal(runtime.status().enabled, true);
        assert.equal(runtime.status().revision, "demo");
    }
    finally
    {
        runtime.dispose();
    }
    assert.deepEqual(Object.getOwnPropertyDescriptor(manifest, "getManifest"), originalManifest);
    assert.deepEqual(Object.getOwnPropertyDescriptor(controller, "show"), originalShow);
    assert.equal(manifest.getManifest(), environment.base);
    assert.equal(environment.listeners.size, 0);
    assert.equal((globalThis as any).__autonomCenter, undefined);
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
            items: [{ id: "unknown", label: "Broken" }],
            tabs: {},
        })), /needs a tab/);
        assert.equal(runtime.status().items[0].label, "Jared");
        await runtime.open("hello");
        assert.equal(runtime.status().activeTab, "hello");
        assert.deepEqual(environment.commands, [{
            command: "devin.desktopNav.openSurface",
            surface: { id: "automations", path: "/autonom/hello" },
        }]);
        await assert.rejects(runtime.open("missing"), /Unknown or hidden/);
        await runtime.update(config({ enabled: false, items: [], tabs: {} }));
        assert.equal(runtime.status().enabled, false);
        assert.equal(runtime.status().activeTab, null);
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
        await runtime.open("hello");
        const cloud = await runtime.setMode("devin-cloud");
        assert.equal(cloud.mode, "devin-cloud");
        assert.equal(cloud.enabled, false);
        assert.equal(environment.services.manifest.getManifest(), environment.base);
        assert.equal(environment.services.groups.getActiveNavSurface().path, "/automations");
        const autonom = await runtime.setMode("autonom");
        assert.equal(autonom.mode, "autonom");
        assert.equal(autonom.enabled, true);
        assert.equal(autonom.activeTab, null);
        await runtime.open("hello");
        assert.equal(runtime.status().activeTab, "hello");
        assert.equal(environment.commands.length, 2);
    }
    finally
    {
        runtime.dispose();
    }
});

test("runtime refuses unsupported native service shapes and invalid configuration", () =>
{
    const environment = fixture();
    const original = environment.services.manifest.getManifest;
    assert.throws(() => install({ ...environment.services, controller: {} }, config()), /Unsupported native/);
    assert.throws(() => install(environment.services, {} as any), /bridge endpoint/);
    assert.equal(environment.services.manifest.getManifest, original);
    assert.equal(environment.listeners.size, 0);
});

test("installing again replaces the previous runtime without leaving descriptors", () =>
{
    const environment = fixture();
    const runtime = install(environment.services, config());
    const replacement = install(environment.services, config());
    assert.notEqual(replacement, runtime);
    assert.equal((globalThis as any).__autonomCenter, replacement);
    replacement.dispose();
    assert.equal((globalThis as any).__autonomCenter, undefined);
    assert.equal(environment.listeners.size, 0);
});
