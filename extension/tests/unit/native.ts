import { install } from "../../source/commandCenter/native";
import { CenterContent } from "../../source/commandCenter/content";

import assert from "node:assert/strict";
import { test } from "node:test";

function fixture(): any {
    const listeners = new Set<() => void>();
    const base = {
        revision: "native",
        schemaVersion: 7,
        items: [{ id: "automations", label: "Automations", icon: "automations", path: "/automations" }],
    };
    const manifest = {
        getManifest(): any {
            return base;
        },
        _onDidChangeManifest: {
            fire(): void {
                for (const listener of listeners)
                    listener();
            },
        },
        onDidChangeManifest(listener: () => void): { dispose(): void } {
            listeners.add(listener);
            return {
                dispose(): void {
                    listeners.delete(listener);
                },
            };
        },
    };
    const commands: unknown[] = [];
    let active: { id: string; path: string } | null = null;
    const groups = {
        getActiveNavSurface(): unknown {
            return active;
        },
        setActiveNavSurface(_window: number, surface: { id: string; path: string } | null): void {
            active = surface;
        },
    };
    const controller = {
        show(): void {
            return;
        },
        setVisible(): void {
            return;
        },
        resetActiveSurface(): void {
            return;
        },
        reloadActiveSurface(): void {
            return;
        },
        _load(): void {
            return;
        },
    };
    return {
        services: {
            manifest,
            groups,
            controller,
            windowId: 2,
            api: {
                async executeCommand(command: string, surface: { id: string; path: string }): Promise<void> {
                    commands.push({ command, surface });
                    active = surface;
                },
            },
        },
        base,
        listeners,
        commands,
    };
}

const content: CenterContent = {
    enabled: true,
    revision: "demo",
    items: [{ id: "automations", label: "Jared", tab: "hello" }],
    tabs: { hello: { title: "Hello", html: "<h1>Hello world</h1>" } },
};

test("runtime caches immutable manifest overlays and restores exact descriptors", async () => {
    const environment = fixture();
    const manifest = environment.services.manifest;
    const controller = environment.services.controller;
    const originalManifest = Object.getOwnPropertyDescriptor(manifest, "getManifest");
    const originalShow = Object.getOwnPropertyDescriptor(controller, "show");
    const runtime = install(environment.services, "unit-owner");
    try {
        assert.equal(manifest.getManifest(), environment.base);
        await runtime.update(content);
        const first = manifest.getManifest();
        assert.equal(first, manifest.getManifest());
        assert.equal(first.items[0].label, "Jared");
        assert.equal(environment.base.items[0].label, "Automations");
        assert.equal(environment.base.revision, "native");
        manifest._onDidChangeManifest.fire(environment.base);
        assert.equal(manifest.getManifest().items[0].label, "Jared");
        assert.equal(runtime.status().connected, true);
        assert.throws(() => install(environment.services, "another-owner"), /another extension activation/);
        assert.equal(install(environment.services, "unit-owner"), runtime);
    } finally {
        runtime.dispose();
    }
    assert.deepEqual(Object.getOwnPropertyDescriptor(manifest, "getManifest"), originalManifest);
    assert.deepEqual(Object.getOwnPropertyDescriptor(controller, "show"), originalShow);
    assert.equal(manifest.getManifest(), environment.base);
    assert.equal(environment.listeners.size, 0);
    assert.equal((globalThis as any).__autonomCenter, undefined);
});

test("runtime reload is atomic and open tab uses native navigation", async () => {
    const environment = fixture();
    const runtime = install(environment.services, "unit-owner");
    try {
        await runtime.update(content);
        await assert.rejects(runtime.update({ ...content, items: [{ id: "unknown", label: "Broken" }] }), /needs a tab/);
        assert.equal(runtime.status().items[0].label, "Jared");
        await runtime.open("hello");
        assert.equal(runtime.status().activeTab, "hello");
        assert.deepEqual(environment.commands, [{
            command: "devin.desktopNav.openSurface",
            surface: { id: "automations", path: "/autonom/hello" },
        }]);
        await assert.rejects(runtime.open("missing"), /Unknown or hidden/);
        await runtime.update({ enabled: false, items: [], tabs: {} });
        assert.equal(runtime.status().enabled, false);
        assert.equal(runtime.status().activeTab, null);
        assert.equal(environment.services.groups.getActiveNavSurface().path, "/automations");
        assert.equal(environment.services.manifest.getManifest(), environment.base);
    } finally {
        runtime.dispose();
    }
});

test("provider mode returns to native Devin navigation and can switch back without a reload", async () => {
    const environment = fixture();
    const runtime = install(environment.services, "unit-owner");
    try {
        await runtime.update(content);
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
    } finally {
        runtime.dispose();
    }
});

test("runtime refuses unsupported native service shapes before mutation", () => {
    const environment = fixture();
    const original = environment.services.manifest.getManifest;
    assert.throws(() => install({ ...environment.services, controller: {} }, "unit-owner"), /Unsupported native/);
    assert.equal(environment.services.manifest.getManifest, original);
    assert.equal(environment.listeners.size, 0);
});
