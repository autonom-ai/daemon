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
import { CenterContent, NativeItem, autonomPageHtml, overlayItems, pageHtml } from "./content";

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
    isAutonom?: boolean;
    messageSub?: { dispose(): void };
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

    const DEVIN_CLOUD_IDS = new Set(["review", "automations", "security", "wiki", "desktop-settings"]);

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
            const filteredBaseItems = (base.items as NativeItem[]).filter((item) => !DEVIN_CLOUD_IDS.has(item.id));
            cachedManifest = Object.assign(Object.create(Object.getPrototypeOf(base)), base, {
                items: overlayItems(filteredBaseItems, { ...content, enabled: true }),
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
        const isAutonomTab = content.tabs[tab]?.autonom === true;
        if (!view || !view.host.isConnected || view.isAutonom !== isAutonomTab) {
            removeView(instance);
            const host = shell._hostEl.ownerDocument.createElement("div") as HTMLElement;
            host.dataset.autonomCenter = "page";
            host.style.cssText = "position:absolute;inset:0;width:100%;height:100%;z-index:1;";
            shell._hostEl.appendChild(host);
            const webview = shell._webviewService.createWebviewElement({
                title: content.tabs[tab]!.title,
                options: { retainContextWhenHidden: true, enableFindWidget: true },
                contentOptions: {
                    enableScripts: isAutonomTab,
                    allowScripts: isAutonomTab,
                    enableForms: isAutonomTab,
                    allowForms: isAutonomTab,
                    localResourceRoots: [],
                },
                extension: undefined,
            });
            webview.mountTo(host, shell._hostEl.ownerDocument.defaultView);
            const messageSub = (isAutonomTab && typeof webview.onMessage === "function")
                ? webview.onMessage(async (e: any) => {
                    const message = e?.message ?? e;
                    if (!message || typeof message !== "object")
                        return;
                    const reqId = message.reqId || message.id;
                    if (!reqId)
                        return;
                    try {
                        const result = await api.executeCommand("autonomCenter.daemonRequest", message);
                        webview.postMessage({ reqId, id: reqId, result });
                    } catch (err: any) {
                        webview.postMessage({ reqId, id: reqId, error: err?.message || String(err) });
                    }
                })
                : undefined;
            view = {
                controller: instance,
                host,
                webview,
                isAutonom: isAutonomTab,
                messageSub,
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
                        messageSub?.dispose?.();
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
        const html = content.tabs[tab]?.autonom
            ? (content.tabs[tab]!.html.startsWith("<!DOCTYPE") ? content.tabs[tab]!.html : autonomPageHtml(content.tabs[tab]!))
            : pageHtml(content.tabs[tab]!);
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
    /**
     * Autonom logo icon.
     * Source: Streamline (https://www.streamlinehq.com)
     * License: Creative Commons Attribution 4.0 International (CC BY 4.0)
     */
    const AUTONOM_ICON_PATH = "M15.319 14.318c-1.397-.295-1.905-1.712-1.22-2.965c2.923-5.349 6.424-8.2 8.382-9.484a2.74 2.74 0 0 1 3.038 0c1.958 1.285 5.459 4.135 8.382 9.484c.685 1.253.177 2.67-1.22 2.965c-1.647.347-4.355.682-8.681.682s-7.034-.335-8.681-.682m23.784 13.3c.91-1.003 2.266-.728 3.017.413c3.453 5.246 4.525 9.676 4.852 12.151c.176 1.328-.492 2.552-1.667 3.055c-2.19.938-6.355 2.17-12.376 1.631c-1.31-.117-2.213-1.221-1.847-2.556c.43-1.57 1.366-4.046 3.38-7.733c2.012-3.687 3.572-5.782 4.641-6.961M5.88 28.03c.75-1.14 2.107-1.416 3.017-.413c1.07 1.179 2.63 3.274 4.642 6.961s2.948 6.164 3.379 7.733c.366 1.335-.537 2.439-1.847 2.556c-6.021.54-10.186-.693-12.376-1.631c-1.175-.503-1.843-1.727-1.667-3.055c.327-2.475 1.4-6.905 4.852-12.15M24 17.5c-1.9 0-3.517-.063-4.89-.165c.264 2.844.591 6.132.938 9.027a358 358 0 0 0-6.708 2.999a57 57 0 0 1 2.393 4.02a57 57 0 0 1 2.207 4.457a377 377 0 0 0 5.66-4.088c2.066 1.526 4.3 3.127 6.273 4.522c.577-1.367 1.353-2.985 2.394-4.891a58 58 0 0 1 2.209-3.738a389 389 0 0 0-6.565-2.95c.362-2.974.705-6.406.978-9.359A66 66 0 0 1 24 17.5";

    const DEVIN_CLOUD_ICON_PATH = "M4.406 3.342A5.53 5.53 0 0 1 8 2c2.69 0 4.923 2 5.166 4.579C14.758 6.804 16 8.137 16 9.773 16 11.569 14.502 13 12.687 13H3.781C1.708 13 0 11.366 0 9.318c0-1.763 1.266-3.223 2.942-3.593.143-.863.698-1.723 1.464-2.383";

    function createSvgIcon(viewBox: string, pathD: string): SVGSVGElement {
        const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        svg.setAttribute("viewBox", viewBox);
        svg.setAttribute("width", "14");
        svg.setAttribute("height", "14");
        svg.setAttribute("fill", "currentColor");
        svg.setAttribute("aria-hidden", "true");
        svg.style.flexShrink = "0";
        svg.style.pointerEvents = "none";
        const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
        path.setAttribute("fill-rule", "evenodd");
        path.setAttribute("clip-rule", "evenodd");
        path.setAttribute("d", pathD);
        svg.appendChild(path);
        return svg;
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
            providerRow.style.margin = "2px 0 8px 0";
            providerRow.style.padding = "0";
            menu.insertBefore(providerRow, reference);
            const switchRoot = document.createElement("div");
            switchRoot.className = "agent-editor-switch";
            switchRoot.setAttribute("role", "group");
            switchRoot.setAttribute("aria-label", "Command Center provider");
            switchRoot.style.width = "100%";
            const segments = document.createElement("div");
            segments.className = "switch-container";
            segments.style.width = "100%";
            segments.style.height = "28px";
            segments.style.padding = "2px";
            segments.style.boxSizing = "border-box";
            segments.style.display = "flex";
            segments.style.alignItems = "center";
            segments.style.borderRadius = "7px";
            segments.style.backgroundColor = "var(--windsurf-switch-background, rgba(230, 230, 230, 0.05))";
            for (const [provider, label, viewBox, pathD] of [
                ["autonom", "Autonom", "0 0 48 48", AUTONOM_ICON_PATH],
                ["devin-cloud", "Devin Cloud", "0 0 16 16", DEVIN_CLOUD_ICON_PATH],
            ] as const) {
                const button = document.createElement("button");
                button.type = "button";
                button.className = "switch-segment";
                button.style.flex = "1 1 0";
                button.style.minWidth = "0";
                button.style.height = "100%";
                button.style.display = "flex";
                button.style.alignItems = "center";
                button.style.justifyContent = "center";
                button.style.gap = "6px";
                button.style.padding = "0 8px";
                button.style.borderRadius = "5px";
                button.style.border = "1px solid transparent";
                button.style.boxSizing = "border-box";
                button.style.fontSize = "12px";
                button.style.fontWeight = "500";
                button.style.cursor = "pointer";
                button.style.userSelect = "none";
                button.style.transition = "background-color 0.15s ease, color 0.15s ease";
                button.dataset.autonomProvider = provider;
                button.setAttribute("aria-label", label);

                const iconSpan = document.createElement("span");
                iconSpan.className = "segment-icon";
                iconSpan.style.display = "inline-flex";
                iconSpan.style.alignItems = "center";
                iconSpan.style.justifyContent = "center";
                iconSpan.style.lineHeight = "0";
                iconSpan.style.flexShrink = "0";
                iconSpan.appendChild(createSvgIcon(viewBox, pathD));
                button.appendChild(iconSpan);

                const text = document.createElement("span");
                text.className = "segment-label";
                text.style.overflow = "hidden";
                text.style.textOverflow = "ellipsis";
                text.style.whiteSpace = "nowrap";
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
            button.style.backgroundColor = active ? "rgb(var(--bg-accent-primary, 0 120 212))" : "transparent";
            button.style.color = active
                ? "var(--vscode-button-foreground, var(--text-primary-strong, #fff))"
                : "var(--text-secondary, currentColor)";
            button.style.boxShadow = active ? "0 1px 2px rgba(0, 0, 0, 0.1)" : "none";
        }
    }

    const DEVIN_LOCAL = "Devin Local";
    let keydownListenerAttached = false;
    let acpStoreUnsubscribe: (() => void) | undefined;
    const registeredSessionIds = new Set<string>();

    function onKeyDown(e: KeyboardEvent): void {
        if (mode === "autonom" && (e.ctrlKey || e.metaKey) && (e.key === "'" || e.code === "Quote")) {
            e.stopImmediatePropagation();
            e.preventDefault();
        }
    }

    function attachSessionWatcher(): void {
        if (acpStoreUnsubscribe)
            return;
        const store = (globalThis as any).__acpStore;
        if (!store || typeof store.subscribe !== "function")
            return;
        acpStoreUnsubscribe = store.subscribe(() => {
            if (mode !== "autonom")
                return;
            const state = store.getState();
            const focused = state?.acp?.focusedSessionId;
            if (typeof focused === "string" && focused.length > 0) {
                const sessionId = focused.includes("/") ? focused.split("/").pop()! : focused;
                if (sessionId && !registeredSessionIds.has(sessionId) && /^[a-z0-9_-]+$/i.test(sessionId)) {
                    registeredSessionIds.add(sessionId);
                    void api.executeCommand("autonomCenter.daemonRequest", {
                        action: "registerSession",
                        id: sessionId,
                    }).catch(() => {});
                }
            }
        });
    }

    let overrideStyle: HTMLStyleElement | undefined;

    function updateOverrideStyles(): void {
        const document = globalThis.document;
        if (!document?.head)
            return;
        if (mode === "autonom" && content.enabled) {
            if (!overrideStyle || !overrideStyle.isConnected) {
                overrideStyle?.remove();
                overrideStyle = document.createElement("style");
                overrideStyle.id = "autonom-native-overrides";
                document.head.appendChild(overrideStyle);
            }
            overrideStyle.textContent = `
                aside[data-slot="sidebar"] > *:not([data-slot="sidebar-header"]) {
                    display: none !important;
                }
                div[class*="max-w-[200px]"] button[aria-haspopup="menu"] {
                    pointer-events: none !important;
                    cursor: default !important;
                }
            `;
        } else {
            overrideStyle?.remove();
            overrideStyle = undefined;
        }
    }

    let isSyncing = false;
    function syncAutonomDomState(): void {
        const document = globalThis.document;
        if (!document?.body || isSyncing)
            return;
        isSyncing = true;
        try {
            updateOverrideStyles();
            renderProviderToggle();

        if (!keydownListenerAttached) {
            document.addEventListener("keydown", onKeyDown, true);
            keydownListenerAttached = true;
        }

        attachSessionWatcher();

        const aside = document.querySelector<HTMLElement>('aside[data-slot="sidebar"]');
        const asideChildren = aside ? (Array.from(aside.children) as HTMLElement[]) : [];
        const header = aside?.querySelector<HTMLElement>('[data-slot="sidebar-header"]');

        if (mode === "autonom") {
            // 1. Sidebar: keep only sidebar-header (provider toggle + New session button).
            // Hide everything below it so the sidebar is clean and empty below New session.
            for (const child of asideChildren) {
                if (child !== header && !child.contains(header || null)) {
                    child.style.display = "none";
                }
            }

            // 2. Hide any Spaces / Split into new space groups anywhere in sidebar
            for (const group of document.querySelectorAll<HTMLElement>('[data-slot="sidebar-group"]')) {
                const text = group.textContent || "";
                if (text.includes("Spaces") || text.includes("Split into new space")) {
                    group.style.display = "none";
                }
            }

            // 3. Hook New session button to hide any open custom page webview
            const newSessionBtn = document.querySelector<HTMLButtonElement>('button[aria-label="New session"]');
            if (newSessionBtn && !(newSessionBtn as any).__autonomHooked) {
                (newSessionBtn as any).__autonomHooked = true;
                newSessionBtn.addEventListener("click", () => {
                    if (mode === "autonom") {
                        for (const view of views.values()) {
                            view.host.style.display = "none";
                        }
                    }
                }, true);
            }

            // 4. Lock ACP selector in composer and active session to "Devin Local" and disable clicks
            const buttons = document.querySelectorAll<HTMLButtonElement>("button");
            for (const btn of buttons) {
                if (btn.classList.contains("switch-segment"))
                    continue;
                const isAcpParent = btn.parentElement?.className?.includes("max-w-[200px]");
                const text = btn.textContent?.trim() || "";
                const isAcpText = ["Devin Local", "Codex", "OpenCode", "Antigravity (DBA)", "Devin Cloud"].includes(text);
                if ((isAcpParent || isAcpText) && btn.getAttribute("aria-haspopup") === "menu") {
                    const span = btn.querySelector("span");
                    if (span && span.textContent !== DEVIN_LOCAL) {
                        span.textContent = DEVIN_LOCAL;
                    }
                    btn.style.pointerEvents = "none";
                    btn.style.cursor = "default";
                    btn.setAttribute("data-disabled", "");
                    btn.setAttribute("aria-disabled", "true");
                    btn.tabIndex = -1;
                }
            }

            // 5. Suppress ACP agent switch popup menu
            for (const popup of document.querySelectorAll<HTMLElement>('[role="menu"], [data-slot="menu"], [class*="popup"]')) {
                const text = popup.textContent || "";
                if (text.includes("switch agents") || (text.includes("Devin Local") && (text.includes("Codex") || text.includes("OpenCode")))) {
                    popup.style.display = "none";
                    popup.remove();
                }
            }
        } else {
            // Restore native sidebar in Devin Cloud mode
            for (const child of asideChildren) {
                child.style.display = "";
            }
            for (const group of document.querySelectorAll<HTMLElement>('[data-slot="sidebar-group"]')) {
                group.style.display = "";
            }
            // Unlock ACP selector buttons
            for (const btn of document.querySelectorAll<HTMLButtonElement>("button")) {
                if (btn.parentElement?.className?.includes("max-w-[200px]") && btn.getAttribute("aria-haspopup") === "menu") {
                    btn.style.pointerEvents = "";
                    btn.style.cursor = "";
                    btn.removeAttribute("data-disabled");
                    btn.removeAttribute("aria-disabled");
                    btn.tabIndex = 0;
                }
            }
        }
    } finally {
        isSyncing = false;
    }

        if (!providerObserver) {
            providerObserver = new MutationObserver(() => syncAutonomDomState());
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
            syncAutonomDomState();
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
            syncAutonomDomState();
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
            if (keydownListenerAttached) {
                globalThis.document?.removeEventListener("keydown", onKeyDown, true);
                keydownListenerAttached = false;
            }
            if (acpStoreUnsubscribe) {
                acpStoreUnsubscribe();
                acpStoreUnsubscribe = undefined;
            }
            const aside = globalThis.document?.querySelector<HTMLElement>('aside[data-slot="sidebar"]');
            if (aside) {
                for (const child of Array.from(aside.children) as HTMLElement[]) {
                    child.style.display = "";
                }
            }
            for (const group of globalThis.document?.querySelectorAll<HTMLElement>('[data-slot="sidebar-group"]') || []) {
                group.style.display = "";
            }
            for (const btn of globalThis.document?.querySelectorAll<HTMLButtonElement>("button") || []) {
                if (btn.parentElement?.className?.includes("max-w-[200px]") && btn.getAttribute("aria-haspopup") === "menu") {
                    btn.style.pointerEvents = "";
                    btn.style.cursor = "";
                    btn.removeAttribute("data-disabled");
                    btn.removeAttribute("aria-disabled");
                    btn.tabIndex = 0;
                }
            }
            overrideStyle?.remove();
            overrideStyle = undefined;
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
        syncAutonomDomState();
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
