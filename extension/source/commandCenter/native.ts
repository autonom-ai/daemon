/**
 * Renderer-side Command Center runtime.
 *
 * This module is injected into the Devin Desktop workbench renderer and adapts
 * its private navigation services in memory. It is the only code that touches
 * the native React tree and the native surface controller. Every change is
 * reversible: captured property descriptors are restored on dispose, and the
 * native manifest and page webview are never destroyed, only temporarily
 * hidden or overridden. See docs/COMMAND_CENTER.md for the reverse-engineered
 * boundary and docs/COMMAND_CENTER_VALIDATION.md for the acceptance method.
 */
import { CenterContent, NativeItem, overlayItems, pageHtml } from "./content";

export interface RuntimeStatus {
    connected: boolean;
    mode: "autonom" | "devin-cloud";
    enabled: boolean;
    patchOnlyIntegrityNoticeSuppressed: boolean;
    revision: string | null;
    activeTab: string | null;
    windowId: number;
    items: { id: string; label: string; path: string }[];
}

interface CustomView {
    controller: any;
    host: HTMLElement;
    webview: any;
    nativeVisibility: string;
    routeDescriptor: PropertyDescriptor | undefined;
    routeWrapper: Function;
    nativeSurfaceId: unknown;
    nativeTitle: unknown;
    nativeSidebar: unknown;
    stacks: Map<string, unknown>;
    lifetime: { dispose(): void };
    surface: NativeItem;
    html: string;
}

/**
 * Locates the native sidebar's React context object.
 *
 * Walks the React fiber ancestry of the sidebar menu element and returns the
 * first parent whose props expose the navigation snapshot functions and the
 * command API. Bounded depth keeps the walk cheap and predictable; returns
 * null when the sidebar has not mounted yet.
 */
export function probe(): any {
    for (const element of document.querySelectorAll("[data-slot=sidebar-menu], [data-slot=sidebar]")) {
        const key = Object.keys(element).find((name) => name.startsWith("__reactFiber$"));
        let fiber = key ? (element as any)[key] : null;
        for (let index = 0; fiber && index < 128; index++, fiber = fiber.return) {
            const props = fiber.memoizedProps;
            if (typeof props?.getDesktopNavSurfacesSnapshot === "function"
                && typeof props?.getActiveDesktopNavSurfaceSnapshot === "function" && props.vscodeAPI?.executeCommand)
                return { props, api: props.vscodeAPI };
        }
    }
    return null;
}

/**
 * Installs the Command Center runtime for one extension activation.
 *
 * `services` are the native service references captured from the renderer.
 * `owner` is the activation UUID: only the activation that owns the runtime may
 * reuse or dispose it. Validates the native service shape before mutating
 * anything and fails closed on an unrecognized build. Idempotent for the same
 * owner.
 */
export function install(
    services: any,
    owner: string,
    patchOnlyIntegrityNoticeSuppressed = false,
): any {
    const target = globalThis as any;
    if (target.__autonomCenter) {
        if (target.__autonomCenter.owner !== owner)
            throw new Error("This Command Center already belongs to another extension activation.");
        return target.__autonomCenter;
    }
    const { manifest, groups, controller, api, windowId } = services;
    if (!manifest?.getManifest || !manifest?._onDidChangeManifest?.fire || !manifest.onDidChangeManifest
        || !groups?.setActiveNavSurface || !groups?.getActiveNavSurface || !api?.executeCommand
        || !Number.isInteger(windowId) || !controller?.show || !controller?.setVisible
        || !controller?.resetActiveSurface || !controller?.reloadActiveSurface || !controller?._load)
        throw new Error("Unsupported native Command Center service shape.");
    let content: CenterContent = { enabled: false, items: [], tabs: {} };
    let mode: "autonom" | "devin-cloud" = "autonom";
    let generation = 0;
    let cachedBase: any;
    let cachedManifest: any;
    let relaying = false;
    let lease: ReturnType<typeof setTimeout> | undefined;
    let providerObserver: MutationObserver | undefined;
    let providerRow: HTMLLIElement | undefined;
    let integrityObserver: MutationObserver | undefined;
    let isPatchOnlyIntegrityNotice = patchOnlyIntegrityNoticeSuppressed;
    const descriptors: { object: any; name: string; descriptor: PropertyDescriptor | undefined; wrapper: Function }[] = [];
    const views = new Map<any, CustomView>();
    const getManifest = manifest.getManifest;

    /**
     * Returns the native manifest, or a cached overlay of it in Autonom mode.
     *
     * The cache is keyed on the native manifest identity and the config
     * generation so React's external-store snapshot stays referentially stable
     * across renders while still updating when the config or native data
     * changes. Unknown native fields are preserved.
     */
    function effectiveManifest(): any {
        const base = getManifest.call(manifest);
        if (!content.enabled || mode !== "autonom")
            return base;
        if (base !== cachedBase || !cachedManifest) {
            cachedBase = base;
            cachedManifest = Object.assign(Object.create(Object.getPrototypeOf(base)), base, {
                items: overlayItems(base.items, { ...content, enabled: true }),
                revision: `${base.revision}:autonom:${generation}`,
            });
        }
        return cachedManifest;
    }

    /** Replaces an own property and records the descriptor for exact rollback. */
    function wrap(object: any, name: string, wrapper: Function): void {
        descriptors.push({ object, name, descriptor: Object.getOwnPropertyDescriptor(object, name), wrapper });
        Object.defineProperty(object, name, { configurable: true, writable: true, value: wrapper });
    }

    /** Fires the native manifest change event, guarding against re-entrancy. */
    function notify(): void {
        if (relaying)
            return;
        relaying = true;
        try {
            manifest._onDidChangeManifest.fire(effectiveManifest());
        } finally {
            relaying = false;
        }
    }

    /** Returns the custom tab id for a surface, or null for a native surface. */
    function tabFor(surface: any): string | null {
        if (!content.enabled || mode !== "autonom" || typeof surface?.path !== "string")
            return null;
        const tab = surface.path.startsWith("/autonom/") ? surface.path.slice(9) : "";
        return Object.hasOwn(content.tabs, tab) ? tab : null;
    }

    /**
     * Arms or disarms dismissal of the verified legacy integrity toast.
     *
     * `suppressed` is true only when the extension host proved the exact known
     * Autonom 0.4.0 checksum residue. When armed, this observes for the exact
     * toast text and clears it through Devin's own Clear Notification action.
     * It never writes storage or marks the installation pure, and any other
     * warning is left alone.
     */
    function updatePatchOnlyIntegrityNotice(suppressed: boolean): void {
        isPatchOnlyIntegrityNotice = suppressed;
        integrityObserver?.disconnect();
        integrityObserver = undefined;
        if (!suppressed || typeof document === "undefined" || !document.body)
            return;
        const clearVerifiedNotice = (): void => {
            for (const item of document.querySelectorAll<HTMLElement>(
                ".notification-toast .notification-list-item",
            )) {
                const message = item.querySelector(".notification-list-item-message")?.textContent?.trim();
                if (message !== "Your Devin installation appears to be corrupt. Please reinstall.")
                    continue;
                item.querySelector<HTMLElement>('a[aria-label^="Clear Notification"]')?.click();
            }
        };
        clearVerifiedNotice();
        integrityObserver = new MutationObserver(clearVerifiedNotice);
        integrityObserver.observe(document.body, { childList: true, subtree: true });
    }

    /**
     * Tears down a custom page view and restores the native controller state.
     *
     * Reverts the captured route handler, history stacks, active surface id,
     * title, sidebar, and page visibility so native navigation behaves exactly
     * as it did before the custom page opened.
     */
    function removeView(instance: any): void {
        const view = views.get(instance);
        if (!view)
            return;
        views.delete(instance);
        const shell = instance._webview;
        if (shell._mountEl)
            shell._mountEl.style.visibility = view.nativeVisibility;
        if (shell._onActiveRoute === view.routeWrapper) {
            if (view.routeDescriptor)
                Object.defineProperty(shell, "_onActiveRoute", view.routeDescriptor);
            else
                delete shell._onActiveRoute;
        }
        for (const [id, stack] of view.stacks) {
            if (stack === undefined)
                shell._surfaces.delete(id);
            else
                shell._surfaces.set(id, stack);
        }
        shell._activeSurfaceId = view.nativeSurfaceId;
        shell._title = view.nativeTitle;
        shell._activeSidebar = view.nativeSidebar;
        instance._loadedSurfaceId = undefined;
        instance._store?.delete(view.lifetime);
        view.webview.dispose();
        view.host.remove();
    }

    /**
     * Shows a custom page for a surface, or returns false for a native one.
     *
     * Mounts the page in a sibling native webview and hides the native page
     * webview rather than destroying it, so the remote webapp stays loaded and
     * returning to a native surface is instant. The native controller's
     * observable state is updated so history and active-tab reporting stay
     * coherent while the custom page is shown.
     */
    function render(instance: any, surface: NativeItem): boolean {
        const tab = tabFor(surface);
        if (!tab)
            return false;
        const shell = instance._webview;
        if (!shell?._hostEl || !shell?._mountEl || !shell?._webviewService?.createWebviewElement)
            throw new Error("Native page host is not ready.");
        let view = views.get(instance);
        if (!view || !view.host.isConnected) {
            removeView(instance);
            const host = shell._hostEl.ownerDocument.createElement("div") as HTMLElement;
            host.dataset.autonomCenter = "page";
            host.style.cssText = "position:absolute;inset:0;width:100%;height:100%;z-index:1;";
            shell._hostEl.appendChild(host);
            const webview = shell._webviewService.createWebviewElement({
                title: content.tabs[tab]!.title,
                options: { retainContextWhenHidden: true, enableFindWidget: true },
                contentOptions: { allowScripts: false, allowForms: false, localResourceRoots: [] },
                extension: undefined,
            });
            webview.mountTo(host, shell._hostEl.ownerDocument.defaultView);
            view = {
                controller: instance,
                host,
                webview,
                nativeVisibility: shell._mountEl.style.visibility,
                routeDescriptor: Object.getOwnPropertyDescriptor(shell, "_onActiveRoute"),
                routeWrapper: function (): void {
                    return;
                },
                nativeSurfaceId: shell._activeSurfaceId,
                nativeTitle: shell._title,
                nativeSidebar: shell._activeSidebar,
                stacks: new Map(),
                lifetime: {
                    dispose(): void {
                        removeView(instance);
                    },
                },
                surface,
                html: "",
            };
            views.set(instance, view);
            shell._onActiveRoute = view.routeWrapper;
            instance._register(view.lifetime);
        }
        const html = pageHtml(content.tabs[tab]!);
        if (view.html !== html) {
            view.webview.setHtml(html);
            view.html = html;
        }
        view.surface = surface;
        view.host.dataset.autonomTab = tab;
        view.host.style.display = "";
        shell._mountEl.style.visibility = "hidden";
        instance._currentSurface = surface;
        shell._activeSurfaceId = surface.id;
        if (!view.stacks.has(surface.id))
            view.stacks.set(surface.id, shell._surfaces.get(surface.id));
        shell._surfaces.set(surface.id, { stack: [surface.path], cursor: 0, lastRouteCategory: undefined });
        shell._title = content.tabs[tab]!.title;
        shell._activeSidebar = undefined;
        shell._reportState();
        instance.setVisible(true);
        return true;
    }

    /**
     * Renders the Autonom/Devin Cloud switch above New session.
     *
     * Reuses Devin's own `.agent-editor-switch` classes for native styling and
     * keeps both segments equal width with the active segment on the accent
     * color. A small observer re-inserts the row if React replaces the menu,
     * and the row is removed entirely when the overlay is disabled.
     */
    function renderProviderToggle(): void {
        const document = globalThis.document;
        if (!content.enabled || !document?.body) {
            providerRow?.remove();
            providerRow = undefined;
            providerObserver?.disconnect();
            providerObserver = undefined;
            return;
        }
        const menu = [...document.querySelectorAll<HTMLUListElement>("ul[data-slot=sidebar-menu]")]
            .find((candidate) => candidate.querySelector('button[aria-label="New session"]'));
        const reference = menu?.querySelector('button[aria-label="New session"]')?.closest("li");
        if (!menu || !reference) {
            providerRow?.remove();
            providerRow = undefined;
            return;
        }
        if (!providerRow || !providerRow.isConnected || providerRow.parentElement !== menu) {
            providerRow?.remove();
            providerRow = document.createElement("li");
            providerRow.dataset.slot = "sidebar-menu-item";
            providerRow.dataset.autonomProviderSwitch = "true";
            providerRow.className = reference.className;
            menu.insertBefore(providerRow, reference);
            const switchRoot = document.createElement("div");
            switchRoot.className = "agent-editor-switch";
            switchRoot.setAttribute("role", "group");
            switchRoot.setAttribute("aria-label", "Command Center provider");
            switchRoot.style.width = "100%";
            const segments = document.createElement("div");
            segments.className = "switch-container";
            segments.style.width = "100%";
            for (const [provider, label] of [["autonom", "Autonom"], ["devin-cloud", "Devin Cloud"]] as const) {
                const button = document.createElement("button");
                button.type = "button";
                button.className = "switch-segment";
                button.style.flex = "1 1 0";
                button.style.minWidth = "0";
                button.dataset.autonomProvider = provider;
                button.setAttribute("aria-label", label);
                const text = document.createElement("span");
                text.className = "segment-label";
                text.textContent = label;
                button.appendChild(text);
                button.addEventListener("click", (event) => {
                    event.preventDefault();
                    event.stopPropagation();
                    void runtime.setMode(provider);
                });
                segments.appendChild(button);
            }
            switchRoot.appendChild(segments);
            providerRow.appendChild(switchRoot);
        }
        for (const button of providerRow.querySelectorAll<HTMLButtonElement>("button[data-autonom-provider]")) {
            const active = button.dataset.autonomProvider === mode;
            button.setAttribute("aria-pressed", String(active));
            button.classList.toggle("active", active);
            button.style.backgroundColor = active ? "rgb(var(--bg-accent-primary,0 120 212))" : "transparent";
            button.style.color = active
                ? "var(--vscode-button-foreground,var(--text-primary-strong,#fff))"
                : "var(--text-secondary,currentColor)";
        }
        if (!providerObserver) {
            providerObserver = new MutationObserver(() => renderProviderToggle());
            providerObserver.observe(document.body, { childList: true, subtree: true });
        }
    }

    wrap(manifest, "getManifest", effectiveManifest);
    const subscription = manifest.onDidChangeManifest(() => {
        if (relaying)
            return;
        cachedManifest = undefined;
        if (content.enabled && mode === "autonom")
            notify();
    });
    const show = controller.show;
    wrap(controller, "show", async function (this: any, surface: NativeItem): Promise<void> {
        if (render(this, surface))
            return;
        removeView(this);
        return show.call(this, surface);
    });
    for (const name of ["resetActiveSurface", "reloadActiveSurface", "_load", "_remountAndLoad"]) {
        const original = controller[name];
        if (typeof original !== "function")
            continue;
        wrap(controller, name, function (this: any, ...arguments_: unknown[]): unknown {
            if (render(this, this._currentSurface))
                return Promise.resolve();
            return original.apply(this, arguments_);
        });
    }
    const setVisible = controller.setVisible;
    wrap(controller, "setVisible", function (this: any, visible: boolean): void {
        setVisible.call(this, visible);
        const view = views.get(this);
        if (view)
            view.host.style.display = visible ? "" : "none";
    });

    /**
     * The runtime handle returned to the extension host. All state-changing
     * methods are serialized by the host; this object only performs one step at
     * a time and validates ownership before mutating.
     */
    const runtime = {
        owner,
        heartbeat(identity: string, suppressPatchOnlyWarning: boolean): void {
            if (identity !== owner)
                throw new Error("Command Center owner mismatch.");
            updatePatchOnlyIntegrityNotice(suppressPatchOnlyWarning);
            if (lease !== undefined)
                clearTimeout(lease);
            lease = setTimeout(() => runtime.dispose(), 30000);
        },
        updatePatchOnlyIntegrityNotice,
        status(): RuntimeStatus {
            const active = groups.getActiveNavSurface(windowId);
            return {
                connected: true,
                mode,
                enabled: content.enabled && mode === "autonom",
                patchOnlyIntegrityNoticeSuppressed: isPatchOnlyIntegrityNotice,
                revision: content.revision ?? null,
                activeTab: tabFor(active),
                windowId,
                items: effectiveManifest().items.map((item: NativeItem) => ({
                    id: item.id,
                    label: item.label,
                    path: item.path,
                })),
            };
        },
        /**
         * Applies a validated configuration atomically.
         *
         * Validates the overlay before mutating, then updates the manifest,
         * provider row, and any open custom page. A rejected configuration
         * throws before `content` changes, so the previous state stays intact.
         */
        async update(
            next: CenterContent,
            suppressPatchOnlyWarning = isPatchOnlyIntegrityNotice,
        ): Promise<RuntimeStatus> {
            updatePatchOnlyIntegrityNotice(suppressPatchOnlyWarning);
            overlayItems(getManifest.call(manifest).items, {
                ...next,
                enabled: next.enabled && mode === "autonom",
            });
            content = next;
            if (!content.enabled)
                mode = "devin-cloud";
            else if (mode === "devin-cloud" && generation === 0)
                mode = "autonom";
            generation++;
            cachedManifest = undefined;
            notify();
            renderProviderToggle();
            const active = groups.getActiveNavSurface(windowId);
            const effective = effectiveManifest().items.find((item: NativeItem) => item.id === active?.id);
            if (active && (!effective || effective.path !== active.path))
                groups.setActiveNavSurface(windowId, effective ? { id: effective.id, path: effective.path } : null);
            for (const view of [...views.values()]) {
                if (tabFor(view.surface) && effective?.path === view.surface.path)
                    render(view.controller, view.surface);
                else
                    removeView(view.controller);
            }
            if (content.enabled && mode === "autonom" && content.activeTab)
                await runtime.open(content.activeTab);
            return runtime.status();
        },
        async open(tab: string): Promise<RuntimeStatus> {
            const item = effectiveManifest().items.find((item: NativeItem) => item.path === `/autonom/${tab}`);
            if (!content.enabled || mode !== "autonom" || !Object.hasOwn(content.tabs, tab) || !item)
                throw new Error(`Unknown or hidden custom tab: ${tab}`);
            await api.executeCommand("devin.desktopNav.openSurface", { id: item.id, path: item.path });
            return runtime.status();
        },
        /**
         * Switches between the Autonom overlay and native Devin Cloud.
         *
         * Devin Cloud restores the untouched native manifest and removes any
         * custom page; Autonom re-applies the loaded configuration. Both
         * directions take effect without a window reload.
         */
        async setMode(nextMode: "autonom" | "devin-cloud"): Promise<RuntimeStatus> {
            if (nextMode !== "autonom" && nextMode !== "devin-cloud")
                throw new Error("Unknown Command Center provider.");
            if (mode === nextMode)
                return runtime.status();
            const active = groups.getActiveNavSurface(windowId);
            const nativeItems = getManifest.call(manifest).items as NativeItem[];
            mode = nextMode;
            generation++;
            cachedManifest = undefined;
            notify();
            renderProviderToggle();
            if (mode === "devin-cloud") {
                for (const instance of [...views.keys()])
                    removeView(instance);
                if (active?.path?.startsWith("/autonom/")) {
                    const fallback = nativeItems.find((item) => item.id === active.id);
                    groups.setActiveNavSurface(windowId, fallback
                        ? { id: fallback.id, path: fallback.path }
                        : null);
                }
            } else if (content.activeTab) {
                await runtime.open(content.activeTab);
            }
            return runtime.status();
        },
        /**
         * Fully reverses the adapter and restores native behavior.
         *
         * Removes observers and the provider row, tears down custom pages,
         * restores every captured descriptor, returns any custom surface to its
         * native route, and clears the global handle.
         */
        dispose(): void {
            if (lease !== undefined)
                clearTimeout(lease);
            providerObserver?.disconnect();
            providerRow?.remove();
            integrityObserver?.disconnect();
            providerObserver = undefined;
            integrityObserver = undefined;
            providerRow = undefined;
            const active = groups.getActiveNavSurface(windowId);
            const nativeItems = getManifest.call(manifest).items as NativeItem[];
            content = { enabled: false, items: [], tabs: {} };
            mode = "devin-cloud";
            generation++;
            cachedManifest = undefined;
            for (const instance of [...views.keys()])
                removeView(instance);
            subscription.dispose();
            for (const saved of descriptors.reverse()) {
                if (saved.object[saved.name] !== saved.wrapper)
                    continue;
                if (saved.descriptor)
                    Object.defineProperty(saved.object, saved.name, saved.descriptor);
                else
                    delete saved.object[saved.name];
            }
            if (active?.path?.startsWith("/autonom/")) {
                const fallback = nativeItems.find((item) => item.id === active.id);
                groups.setActiveNavSurface(windowId, fallback
                    ? { id: fallback.id, path: fallback.path }
                    : null);
            }
            notify();
            delete target.__autonomCenter;
        },
    };
    target.__autonomCenter = runtime;
    if (content.enabled)
        renderProviderToggle();
    return runtime;
}

/**
 * Hot-swaps the runtime for the same owner, used by the Hot Reload command.
 *
 * Disposes the previous runtime (restoring native descriptors) and installs the
 * rebuilt bundle in place, so runtime/UI changes appear without a Desktop
 * restart. Refuses to steal a runtime owned by a different activation.
 */
export function replace(
    services: any,
    owner: string,
    patchOnlyIntegrityNoticeSuppressed: boolean,
): any {
    const current = (globalThis as any).__autonomCenter;
    if (current) {
        if (current.owner !== owner)
            throw new Error("This Command Center already belongs to another extension activation.");
        current.dispose();
    }
    return install(services, owner, patchOnlyIntegrityNoticeSuppressed);
}
