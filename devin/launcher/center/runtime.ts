import { ActionStore, actionKey } from "./actions";
import type { CenterContent, NativeItem, SidebarItem } from "./content";
import { declaredItems, overlayItems } from "./content";
import { Directory } from "./directory";
import { createLayout } from "./layout";
import { validateConfig, validateServices } from "./native";
import { Patches } from "./patches";
import { runtimeSnapshot } from "./snapshot";
import type { RuntimeConfig, RuntimeStatus } from "./types";
import { createPageViews } from "./views";

export { prepareShell } from "./shell";

const leaseTimeout = 30000;

/** `install` binds the runtime to one window; `update` applies a configuration. */
export function install(services: any, config: RuntimeConfig): any
{
    const target = globalThis as any;
    const { manifest, groups, controller, api, windowId } = services;
    validateServices(services);
    validateConfig(config);

    const replacing = Boolean(target.__autonomCenter);
    const previousMode = target.__autonomCenter?.status().mode;
    const previousNavigation = target.__autonomCenter?.navigationState?.();
    const previousSurface = groups.getActiveNavSurface(windowId);
    const requestedMode = target.__autonomShell?.requestedMode() ?? "autonom";
    target.__autonomCenter?.dispose();
    let content: CenterContent = { enabled: false, sections: [] };
    const actions = new ActionStore(config.bridge, windowId);
    let mode: "autonom" | "devin-cloud" = previousMode ?? requestedMode;
    let savedAutonomSurface: { id: string; path: string } | null = previousNavigation?.autonom ?? null;
    let savedNativeSurface: { id: string; path: string } | null = previousNavigation?.native ?? null;
    let generation = 0;
    let initialized = false;
    let cachedBase: any;
    let cachedManifest: any;
    let notifying = false;
    let disposed = false;
    let lease: ReturnType<typeof setTimeout> | undefined;

    const patches = new Patches();
    const getManifest = manifest.getManifest;
    let items = new Map<string, SidebarItem>();
    const running = new Set<string>();
    let navigation = 0;

    const views = createPageViews(itemFor, actions, () => content.revision, () => disposed);
    const directory = new Directory((message) => actions.request(message), () => layout.render());
    const layout = createLayout({
        directory,
        get content()
        {
            return content;
        },
        get items()
        {
            return items;
        },
        get enabled()
        {
            return content.enabled && mode === "autonom";
        },
        activate: (id) => runtime.activate(id),
    });

    function effectiveManifest(): any
    {
        const base = getManifest.call(manifest);
        if (!content.enabled || mode !== "autonom")
            return base;

        if (base !== cachedBase || !cachedManifest)
        {
            cachedBase = base;
            cachedManifest = Object.assign(Object.create(Object.getPrototypeOf(base)), base, {
                items: overlayItems(base.items, content),
                revision: `${base.revision}:autonom:${generation}`,
            });
        }

        return cachedManifest;
    }

    function notify(): void
    {
        if (notifying)
            return;

        notifying = true;
        try
        {
            manifest._onDidChangeManifest.fire(effectiveManifest());
        }
        finally
        {
            notifying = false;
        }
    }

    function itemFor(surface: any): SidebarItem | undefined
    {
        if (!content.enabled || mode !== "autonom" || typeof surface?.path !== "string")
            return undefined;

        const item = items.get(surface.id);
        return item?.actions?.left_click.type === "html" && surface.path === `/autonom/${item.id}` ? item : undefined;
    }

    patches.wrap(manifest, "getManifest", effectiveManifest);
    const subscription = manifest.onDidChangeManifest(() =>
    {
        if (notifying)
            return;

        cachedManifest = undefined;
        if (content.enabled && mode === "autonom")
            notify();
    });
    const show = controller.show;
    patches.wrap(controller, "show", async function (this: any, surface: NativeItem): Promise<void>
    {
        if (await views.renderLoaded(this, surface))
            return;

        views.remove(this);
        return show.call(this, surface);
    });
    for (const name of ["resetActiveSurface", "reloadActiveSurface", "_load", "_remountAndLoad"])
    {
        const original = controller[name];
        if (typeof original !== "function")
            continue;

        patches.wrap(controller, name, async function (this: any, ...args: unknown[]): Promise<unknown>
        {
            if (await views.renderLoaded(this, this._currentSurface))
                return;

            return original.apply(this, args);
        });
    }

    const setVisible = controller.setVisible;
    patches.wrap(controller, "setVisible", function (this: any, visible: boolean): void
    {
        setVisible.call(this, visible);
        const view = views.all.get(this);
        if (view)
            view.host.hidden = !visible;
    });

    const runtime = {
        mode: () => mode,
        heartbeat(): void
        {
            if (disposed)
                return;

            if (globalThis.document?.body && content.enabled && mode === "autonom")
                directory.refresh();

            clearTimeout(lease);
            lease = setTimeout(() => runtime.dispose(), leaseTimeout);
        },
        status(): RuntimeStatus
        {
            return runtimeSnapshot({
                disposed, mode, content, windowId,
                activeItem: itemFor(groups.getActiveNavSurface(windowId))?.id ?? null,
                editorActive: target.__autonomShell?.editorActive() ?? false,
                manifest: effectiveManifest(),
                loadedActions: actions.sources.size + actions.scripts.size,
                compiledScripts: actions.scripts.size,
            });
        },
        navigationState: () => ({ autonom: savedAutonomSurface, native: savedNativeSurface }),
        async update(next: RuntimeConfig): Promise<RuntimeStatus>
        {
            if (disposed)
                throw new Error("The UI runtime is disposed.");

            validateConfig(next);

            overlayItems(getManifest.call(manifest).items, next.content);
            const nextItems = new Map(declaredItems(next.content).map((item) => [item.id, item]));
            const active = groups.getActiveNavSurface(windowId);
            const initial = !initialized && !target.__autonomShell?.editorActive()
                ? nextItems.get(previousSurface?.id)?.id ?? (!replacing ? next.content.activeItem : undefined) : undefined;
            const selectedIds = new Set([active?.id, initial, ...[...views.all.values()].map((view) => view.surface.id)]);
            if (next.content.enabled && mode === "autonom")
            {
                for (const id of selectedIds)
                {
                    const selected = nextItems.get(id);
                    if (selected?.actions?.left_click.type === "html")
                        await actions.loadPage(selected, next.content.revision);
                }
            }

            if (disposed)
                throw new Error("The UI runtime is disposed.");

            navigation++;
            content = next.content;
            items = nextItems;
            actions.prune(items);

            actions.bridge = next.bridge;
            if (!content.enabled)
                mode = "devin-cloud";

            generation++;
            cachedManifest = undefined;
            notify();
            layout.render();
            runtime.heartbeat();
            const item = effectiveManifest().items.find((entry: NativeItem) => entry.id === active?.id);
            if (active && (!item || item.path !== active.path))
                groups.setActiveNavSurface(windowId, item ? { id: item.id, path: item.path } : null);

            for (const [instance, view] of views.all)
            {
                const selected = itemFor(view.surface);
                if (selected)
                    views.render(instance, view.surface, !view.host.hidden);
                else
                    views.remove(instance);
            }

            if (initial && content.enabled && mode === "autonom" && !target.__autonomShell?.editorActive()
                && items.get(initial)?.actions?.left_click.type === "html")
                await runtime.open(initial);

            initialized = true;
            return runtime.status();
        },
        async open(id: string): Promise<RuntimeStatus>
        {
            if (disposed)
                throw new Error("The UI runtime is disposed.");

            const item = items.get(id);
            if (!content.enabled || mode !== "autonom" || item?.actions?.left_click.type !== "html")
                throw new Error(`Unknown, hidden, or non-HTML item: ${id}`);

            const pending = ++navigation;
            const key = actionKey(item);
            await actions.loadPage(item, content.revision);
            if (disposed || pending !== navigation || mode !== "autonom"
                || !items.get(id)?.actions || actionKey(items.get(id)!) !== key)
                return runtime.status();

            await api.executeCommand("devin.desktopNav.openSurface", { id, path: `/autonom/${id}` });
            return runtime.status();
        },
        async activate(id: string): Promise<void>
        {
            if (disposed)
                throw new Error("The UI runtime is disposed.");

            const item = items.get(id);
            if (!content.enabled || mode !== "autonom" || !item?.actions?.left_click)
                throw new Error(`Unknown or hidden UI action: ${id}`);

            if (running.has(id))
                return;

            running.add(id);
            try
            {
                if (item.actions.left_click.type === "html")
                    await runtime.open(id);
                else
                    await actions.request({ action: "runScript", id, revision: content.revision });
            }
            finally
            {
                running.delete(id);
            }
        },
        hasScript(id: string, version: string): boolean
        {
            return actions.hasScript(items.get(id), version);
        },
        async toggleEditor(): Promise<void>
        {
            await api.executeCommand("devin.webapp.toggleAgentWindow");
        },
        setScript(id: string, version: string, run: (context: any) => Promise<unknown>): void
        {
            actions.setScript(items.get(id), version, run);
        },
        async runScript(id: string, version: string): Promise<void>
        {
            const item = items.get(id);
            const script = item?.actions?.left_click.type === "js" ? actions.scripts.get(actionKey(item)) : undefined;
            if (disposed || !content.enabled || mode !== "autonom" || !script || script.version !== version)
                throw new Error("The JS action is not available in this UI snapshot.");

            const section = content.sections.find((entry) => entry.buttons?.some((button) => button.id === id));
            await script.run(Object.freeze({
                item: Object.freeze({ id, label: items.get(id)?.label ?? id }),
                section: section && Object.freeze({ id: section.id, label: section.label ?? section.id }),
                request: (message: Record<string, unknown>) => actions.request(message),
                open: (itemId: string) => runtime.open(itemId),
                executeCommand: (command: string, ...args: unknown[]) => api.executeCommand(command, ...args),
                refresh: () => actions.request({ action: "reloadUi" }),
            }));
        },
        async setMode(next: "autonom" | "devin-cloud"): Promise<RuntimeStatus>
        {
            if (disposed)
                throw new Error("The UI runtime is disposed.");

            if (next !== "autonom" && next !== "devin-cloud")
                throw new Error("Unknown Command Center provider.");

            if (mode === next)
            {
                if (next === "autonom" && !target.__autonomShell?.editorActive()
                    && !groups.getActiveNavSurface(windowId) && content.activeItem)
                    await runtime.open(content.activeItem);

                return runtime.status();
            }

            const active = groups.getActiveNavSurface(windowId);
            if (mode === "autonom")
                savedAutonomSurface = active;
            else
                savedNativeSurface = active;

            navigation++;
            mode = next;
            cachedManifest = undefined;
            notify();
            layout.render();
            runtime.heartbeat();
            for (const instance of views.all.keys())
                views.remove(instance);

            const saved = next === "autonom" ? savedAutonomSurface : savedNativeSurface;
            const item = effectiveManifest().items.find((entry: NativeItem) => entry.id === (saved?.id ?? active?.id));
            if (item && next === "autonom" && items.get(item.id)?.actions?.left_click.type === "html")
                await runtime.open(item.id);
            else if (item)
                await api.executeCommand("devin.desktopNav.openSurface", { id: item.id, path: item.path });
            else
            {
                groups.setActiveNavSurface(windowId, null);
                if (next === "autonom" && !target.__autonomShell?.editorActive() && content.activeItem)
                    await runtime.open(content.activeItem);
            }

            return runtime.status();
        },
        dispose(): void
        {
            if (disposed)
                return;

            disposed = true;
            clearTimeout(lease);
            directory.dispose();
            layout.dispose();
            target.__autonomShell?.dispose();
            actions.dispose();
            const active = groups.getActiveNavSurface(windowId);
            content = { enabled: false, sections: [] };
            mode = "devin-cloud";
            for (const instance of views.all.keys())
                views.remove(instance);

            subscription.dispose();
            patches.restore();

            if (active?.path?.startsWith("/autonom/"))
            {
                const item = getManifest.call(manifest).items.find((entry: NativeItem) => entry.id === active.id);
                groups.setActiveNavSurface(windowId, item ? { id: item.id, path: item.path } : null);
            }

            notify();
            if (target.__autonomCenter === runtime)
                delete target.__autonomCenter;
        },
    };
    target.__autonomCenter = runtime;
    runtime.heartbeat();
    return runtime;
}
