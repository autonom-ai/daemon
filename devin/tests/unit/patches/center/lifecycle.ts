import { install } from "../../../../launcher/patches/center/runtime";
import { patchStatus } from "../../../../launcher/patches/status";
import { config, fixture } from "../../../support";

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

test("runtime refuses unsupported native service shapes and invalid configuration", () =>
{
    const environment = fixture();
    const original = environment.services.manifest.getManifest;
    assert.throws(() => install({ ...environment.services, controller: {} }, config()), /Unsupported native/);
    assert.throws(() => install(environment.services, {} as any), /bridge endpoint/);
    assert.equal(environment.services.manifest.getManifest, original);
    assert.equal(environment.listeners.size, 0);
});

test("a rejected replacement leaves the working runtime installed", async () =>
{
    const environment = fixture();
    const runtime = install(environment.services, config());
    try
    {
        await runtime.update(config());
        assert.throws(() => install({ ...environment.services, controller: {} }, config()), /Unsupported native/);
        assert.equal((globalThis as any).__autonomCenter, runtime);
        assert.equal(environment.services.manifest.getManifest().items[0].label, "Jared");
    }
    finally
    {
        runtime.dispose();
    }
});

test("disposed runtimes reject late updates and cannot restore the overlay", async () =>
{
    const environment = fixture();
    const runtime = install(environment.services, config());
    await runtime.update(config());
    runtime.dispose();
    await assert.rejects(runtime.update(config()), /disposed/);
    await assert.rejects(runtime.open("automations"), /disposed/);
    assert.equal(environment.services.manifest.getManifest(), environment.base);
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

test("a late wrapper installation failure restores every earlier descriptor and subscription", () =>
{
    const environment = fixture();
    const { controller, manifest } = environment.services;
    Object.defineProperty(controller, "_load", { configurable: false });
    const originalController = Object.getOwnPropertyDescriptors(controller);
    const originalManifest = Object.getOwnPropertyDescriptor(manifest, "getManifest");
    assert.throws(() => install(environment.services, config()), TypeError);
    assert.deepEqual(Object.getOwnPropertyDescriptors(controller), originalController);
    assert.deepEqual(Object.getOwnPropertyDescriptor(manifest, "getManifest"), originalManifest);
    assert.equal(environment.listeners.size, 0);
    assert.equal((globalThis as any).__autonomCenter, undefined);
});

test("a subscription acquisition failure restores the manifest wrapper", () =>
{
    const environment = fixture();
    const manifest = environment.services.manifest;
    const original = Object.getOwnPropertyDescriptor(manifest, "getManifest");
    manifest.onDidChangeManifest = () => { throw new Error("subscription refused"); };
    assert.throws(() => install(environment.services, config()), /subscription refused/);
    assert.deepEqual(Object.getOwnPropertyDescriptor(manifest, "getManifest"), original);
    assert.equal((globalThis as any).__autonomCenter, undefined);
});

test("a throwing subscription disposal leaves sibling cleanup and descriptor restoration running", async () =>
{
    const environment = fixture();
    const { controller, manifest } = environment.services;
    const originalController = Object.getOwnPropertyDescriptors(controller);
    const originalManifest = Object.getOwnPropertyDescriptor(manifest, "getManifest");
    const subscribe = manifest.onDidChangeManifest;
    manifest.onDidChangeManifest = (listener: () => void) =>
    {
        const subscription = subscribe(listener);
        return {
            dispose(): void
            {
                subscription.dispose();
                throw new Error("subscription disposal failed");
            },
        };
    };
    const runtime = install(environment.services, config());
    await runtime.update(config());
    runtime.dispose();
    assert.deepEqual(Object.getOwnPropertyDescriptors(controller), originalController);
    assert.deepEqual(Object.getOwnPropertyDescriptor(manifest, "getManifest"), originalManifest);
    assert.equal(environment.listeners.size, 0);
    assert.equal((globalThis as any).__autonomCenter, undefined);
    assert.equal(patchStatus().find((patch) => patch.name === "command-center.runtime")?.state, "failed");
});

test("the runtime lease renews on heartbeat and restores native services when it expires", async (context) =>
{
    const environment = fixture();
    const { controller, manifest } = environment.services;
    const originalController = Object.getOwnPropertyDescriptors(controller);
    const originalManifest = Object.getOwnPropertyDescriptor(manifest, "getManifest");
    context.mock.timers.enable({ apis: ["setTimeout"] });
    const runtime = install(environment.services, config());
    try
    {
        await runtime.update(config());
        context.mock.timers.tick(29999);
        assert.equal((globalThis as any).__autonomCenter, runtime);
        runtime.heartbeat();
        context.mock.timers.tick(29999);
        assert.equal((globalThis as any).__autonomCenter, runtime);
        context.mock.timers.tick(1);
        assert.equal((globalThis as any).__autonomCenter, undefined);
        assert.deepEqual(Object.getOwnPropertyDescriptors(controller), originalController);
        assert.deepEqual(Object.getOwnPropertyDescriptor(manifest, "getManifest"), originalManifest);
        assert.equal(environment.listeners.size, 0);
        await assert.rejects(runtime.update(config()), /disposed/);
    }
    finally
    {
        runtime.dispose();
    }
});
