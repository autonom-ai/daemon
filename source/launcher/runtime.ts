import autonomFillMarkup from "../../assets/icons/autonom-fill.svg";
import autonomLineMarkup from "../../assets/icons/autonom.svg";
import type { CenterContent, NativeItem } from "./content";
import { isFullDocument, overlayItems, pageHtml } from "./content";

export type RuntimeConfig = {
    content: CenterContent;
    bridge: {
        url: string;
        token: string;
    };
};

export type RuntimeStatus = {
    connected: boolean;
    mode: "autonom" | "devin-cloud";
    enabled: boolean;
    revision: string | null;
    activeTab: string | null;
    windowId: number;
    items: { id: string; label: string; path: string }[];
};

type CustomView = {
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
};

const DEVIN_CLOUD_IDS = new Set(["sessions", "review", "automations", "security", "wiki", "desktop-settings"]);
const DEVIN_LOCAL = "Devin Local";
const LEASE_TIMEOUT = 30000;

const AUTONOM_FILL_PATH = iconPath(autonomFillMarkup);
const AUTONOM_LINE_PATH = iconPath(autonomLineMarkup);
const CLOUD_FILL_PATH = "M4.406 3.342A5.53 5.53 0 0 1 8 2c2.69 0 4.923 2 5.166 4.579C14.758 6.804 16 8.137 16 9.773 16 11.569 14.502 13 12.687 13H3.781C1.708 13 0 11.366 0 9.318c0-1.763 1.266-3.223 2.942-3.593.143-.863.698-1.723 1.464-2.383";
const CLOUD_LINE_PATH = "M4.406 3.342A5.53 5.53 0 0 1 8 2c2.69 0 4.923 2 5.166 4.579C14.758 6.804 16 8.137 16 9.773 16 11.569 14.502 13 12.687 13H3.781C1.708 13 0 11.366 0 9.318c0-1.763 1.266-3.223 2.942-3.593.143-.863.698-1.723 1.464-2.383zm.653.757c-.757.653-1.153 1.44-1.153 2.056v.448l-.445.049C2.064 6.805 1 7.952 1 9.318 1 10.785 2.23 12 3.781 12h8.906C13.98 12 15 10.988 15 9.773c0-1.216-1.02-2.228-2.313-2.228h-.5v-.5C12.188 4.825 10.328 3 8 3a4.53 4.53 0 0 0-2.941 1.1z";

function iconPath(markup: string): string
{
    return /[\s]d="([^"]+)"/.exec(markup)?.[1] ?? "";
}

/** `install` binds the runtime to one window; `update` applies a configuration. */
export function install(services: any, config: RuntimeConfig): any
{
    const target = globalThis as any;
    target.__autonomCenter?.dispose();
    const { manifest, groups, controller, api, windowId } = services;
    if (!manifest?.getManifest || !manifest?._onDidChangeManifest?.fire || !manifest.onDidChangeManifest
        || !groups?.setActiveNavSurface || !groups?.getActiveNavSurface || !api?.executeCommand
        || !Number.isInteger(windowId) || !controller?.show || !controller?.setVisible
        || !controller?.resetActiveSurface || !controller?.reloadActiveSurface || !controller?._load)
        throw new Error("Unsupported native Command Center service shape.");
    if (!config?.content || !config.bridge?.url || !config.bridge?.token)
        throw new Error("The Command Center runtime needs content and a bridge endpoint.");
    let content: CenterContent = { enabled: false, items: [], tabs: {} };
    let bridge = config.bridge;
    let mode: "autonom" | "devin-cloud" = "autonom";
    let autonomActiveSurface: { id: string; path: string } | null = null;
    let devinCloudActiveSurface: { id: string; path: string } | null = null;
    let autonomPageVisible = false;
    let generation = 0;
    let cachedBase: any;
    let cachedManifest: any;
    let relaying = false;
    let lease: ReturnType<typeof setTimeout> | undefined;
    let providerObserver: MutationObserver | undefined;
    let providerRow: HTMLLIElement | undefined;
    const descriptors: { object: any; name: string; descriptor: PropertyDescriptor | undefined; wrapper: Function }[] = [];
    const views = new Map<any, CustomView>();
    const getManifest = manifest.getManifest;

    function effectiveManifest(): any
    {
        const base = getManifest.call(manifest);
        if (!content.enabled || mode !== "autonom")
            return base;
        if (base !== cachedBase || !cachedManifest)
        {
            cachedBase = base;
            const filteredBaseItems = (base.items as NativeItem[]).filter((item) => !DEVIN_CLOUD_IDS.has(item.id));
            cachedManifest = Object.assign(Object.create(Object.getPrototypeOf(base)), base, {
                items: overlayItems(filteredBaseItems, { ...content, enabled: true }),
                revision: `${base.revision}:autonom:${generation}`,
            });
        }
        return cachedManifest;
    }

    function wrap(object: any, name: string, wrapper: Function): void
    {
        descriptors.push({ object, name, descriptor: Object.getOwnPropertyDescriptor(object, name), wrapper });
        Object.defineProperty(object, name, { configurable: true, writable: true, value: wrapper });
    }

    function notify(): void
    {
        if (relaying)
            return;
        relaying = true;
        try
        {
            manifest._onDidChangeManifest.fire(effectiveManifest());
        }
        finally
        {
            relaying = false;
        }
    }

    function tabFor(surface: any): string | null
    {
        if (!content.enabled || mode !== "autonom" || typeof surface?.path !== "string")
            return null;
        const tab = surface.path.startsWith("/autonom/") ? surface.path.slice(9) : "";
        return Object.hasOwn(content.tabs, tab) ? tab : null;
    }

    async function bridgeRequest(message: Record<string, unknown>): Promise<any>
    {
        const response = await fetch(`${bridge.url}/request`, {
            method: "POST",
            headers: { "content-type": "application/json", "x-autonom-bridge": bridge.token },
            body: JSON.stringify(message),
        });
        const body = await response.json().catch(() => undefined);
        if (!response.ok)
            throw new Error(body?.error || `The Command Center bridge returned HTTP ${response.status}.`);
        return body?.result;
    }

    function removeView(instance: any): void
    {
        const view = views.get(instance);
        if (!view)
            return;
        views.delete(instance);
        autonomPageVisible = false;
        const shell = instance._webview;
        if (shell._mountEl)
            shell._mountEl.style.visibility = view.nativeVisibility;
        if (shell._onActiveRoute === view.routeWrapper)
        {
            if (view.routeDescriptor)
                Object.defineProperty(shell, "_onActiveRoute", view.routeDescriptor);
            else
                delete shell._onActiveRoute;
        }
        for (const [id, stack] of view.stacks)
        {
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

    function render(instance: any, surface: NativeItem): boolean
    {
        const tab = tabFor(surface);
        if (!tab)
            return false;
        const page = content.tabs[tab]!;
        const shell = instance._webview;
        if (!shell?._hostEl || !shell?._mountEl || !shell?._webviewService?.createWebviewElement)
            throw new Error("Native page host is not ready.");
        let view = views.get(instance);
        const enableScripts = isFullDocument(page.html);
        if (!view || !view.host.isConnected || view.isAutonom !== enableScripts)
        {
            removeView(instance);
            const host = shell._hostEl.ownerDocument.createElement("div") as HTMLElement;
            host.dataset.autonomCenter = "page";
            host.style.cssText = "position:absolute;inset:0;width:100%;height:100%;z-index:1;";
            shell._hostEl.appendChild(host);
            const webview = shell._webviewService.createWebviewElement({
                title: page.title,
                options: { retainContextWhenHidden: true, enableFindWidget: true },
                contentOptions: {
                    enableScripts,
                    allowScripts: enableScripts,
                    enableForms: enableScripts,
                    allowForms: enableScripts,
                    localResourceRoots: [],
                },
                extension: undefined,
            });
            webview.mountTo(host, shell._hostEl.ownerDocument.defaultView);
            const messageSub = (enableScripts && typeof webview.onMessage === "function")
                ? webview.onMessage(async (event: any) =>
                {
                    const message = event?.message ?? event;
                    if (!message || typeof message !== "object")
                        return;
                    const reqId = message.reqId || message.id;
                    if (!reqId)
                        return;
                    try
                    {
                        webview.postMessage({ reqId, id: reqId, result: await bridgeRequest(message) });
                    }
                    catch (error: any)
                    {
                        webview.postMessage({ reqId, id: reqId, error: error?.message || String(error) });
                    }
                })
                : undefined;
            view = {
                controller: instance,
                host,
                webview,
                isAutonom: enableScripts,
                messageSub,
                nativeVisibility: shell._mountEl.style.visibility,
                routeDescriptor: Object.getOwnPropertyDescriptor(shell, "_onActiveRoute"),
                routeWrapper: function (): void
                {
                    return;
                },
                nativeSurfaceId: shell._activeSurfaceId,
                nativeTitle: shell._title,
                nativeSidebar: shell._activeSidebar,
                stacks: new Map(),
                lifetime: {
                    dispose(): void
                    {
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
        const html = enableScripts ? page.html : pageHtml(page);
        if (view.html !== html)
        {
            view.webview.setHtml(html);
            view.html = html;
        }
        view.surface = surface;
        view.host.dataset.autonomTab = tab;
        view.host.style.display = "";
        autonomPageVisible = true;
        autonomActiveSurface = { id: surface.id, path: surface.path };
        shell._mountEl.style.visibility = "hidden";
        instance._currentSurface = surface;
        shell._activeSurfaceId = surface.id;
        if (!view.stacks.has(surface.id))
            view.stacks.set(surface.id, shell._surfaces.get(surface.id));
        shell._surfaces.set(surface.id, { stack: [surface.path], cursor: 0, lastRouteCategory: undefined });
        shell._title = page.title;
        shell._activeSidebar = undefined;
        shell._reportState();
        instance.setVisible(true);
        return true;
    }

    function createSvgIcon(viewBox: string, pathD: string): SVGSVGElement
    {
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

    function renderProviderToggle(): void
    {
        const document = globalThis.document;
        if (!content.enabled || !document?.body)
        {
            providerRow?.remove();
            providerRow = undefined;
            providerObserver?.disconnect();
            providerObserver = undefined;
            return;
        }
        const menu = [...document.querySelectorAll<HTMLUListElement>("ul[data-slot=sidebar-menu]")]
            .find((candidate) => candidate.querySelector('button[aria-label="New session"]'));
        const reference = menu?.querySelector('button[aria-label="New session"]')?.closest("li");
        if (!menu || !reference)
        {
            providerRow?.remove();
            providerRow = undefined;
            return;
        }
        if (!providerRow || !providerRow.isConnected || providerRow.parentElement !== menu)
        {
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
            for (const [provider, label] of [
                ["autonom", "Autonom"],
                ["devin-cloud", "Devin Cloud"],
            ] as const)
            {
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
                button.style.transition = "background-color 0.15s ease, color 0.15s ease, border-color 0.15s ease, opacity 0.15s ease";
                button.dataset.autonomProvider = provider;
                button.setAttribute("aria-label", label);

                const iconSpan = document.createElement("span");
                iconSpan.className = "segment-icon";
                iconSpan.style.display = "inline-flex";
                iconSpan.style.alignItems = "center";
                iconSpan.style.justifyContent = "center";
                iconSpan.style.lineHeight = "0";
                iconSpan.style.flexShrink = "0";
                const isAutonom = provider === "autonom";
                iconSpan.appendChild(createSvgIcon(isAutonom ? "0 0 48 48" : "0 0 16 16",
                    isAutonom ? AUTONOM_FILL_PATH : CLOUD_LINE_PATH));
                button.appendChild(iconSpan);

                const text = document.createElement("span");
                text.className = "segment-label";
                text.style.overflow = "hidden";
                text.style.textOverflow = "ellipsis";
                text.style.whiteSpace = "nowrap";
                text.textContent = label;
                button.appendChild(text);

                button.addEventListener("click", (event) =>
                {
                    event.preventDefault();
                    event.stopPropagation();
                    void runtime.setMode(provider);
                });
                segments.appendChild(button);
            }
            switchRoot.appendChild(segments);
            providerRow.appendChild(switchRoot);
        }
        for (const button of providerRow.querySelectorAll<HTMLButtonElement>("button[data-autonom-provider]"))
        {
            const isAutonom = button.dataset.autonomProvider === "autonom";
            const active = button.dataset.autonomProvider === mode;
            button.setAttribute("aria-pressed", String(active));
            button.classList.toggle("active", active);
            button.style.backgroundColor = active ? "rgb(var(--bg-elevated-transparent))" : "transparent";
            button.style.borderColor = active ? "rgb(var(--border-secondary, 255 255 255 / 0.1))" : "transparent";
            button.style.color = active
                ? "var(--text-primary, var(--vscode-titleBar-activeForeground, #fff))"
                : "var(--text-secondary, currentColor)";
            button.style.opacity = active ? "1" : "0.56";
            button.style.boxShadow = active ? "rgba(0, 0, 0, 0.05) 0px 1px 2px" : "none";

            const path = button.querySelector<SVGPathElement>("path");
            const svg = button.querySelector<SVGSVGElement>("svg");
            const expectedViewBox = isAutonom ? "0 0 48 48" : "0 0 16 16";
            const expectedPath = isAutonom
                ? (active ? AUTONOM_FILL_PATH : AUTONOM_LINE_PATH)
                : (active ? CLOUD_FILL_PATH : CLOUD_LINE_PATH);
            if (svg && svg.getAttribute("viewBox") !== expectedViewBox)
                svg.setAttribute("viewBox", expectedViewBox);
            if (path && path.getAttribute("d") !== expectedPath)
                path.setAttribute("d", expectedPath);
        }
    }

    let keydownListenerAttached = false;
    let acpStoreUnsubscribe: (() => void) | undefined;
    const registeredSessionIds = new Set<string>();

    function onKeyDown(event: KeyboardEvent): void
    {
        if (mode === "autonom" && (event.ctrlKey || event.metaKey) && (event.key === "'" || event.code === "Quote"))
        {
            event.stopImmediatePropagation();
            event.preventDefault();
        }
    }

    function attachSessionWatcher(): void
    {
        if (acpStoreUnsubscribe)
            return;
        const store = (globalThis as any).__acpStore;
        if (!store || typeof store.subscribe !== "function")
            return;
        acpStoreUnsubscribe = store.subscribe(() =>
        {
            if (mode !== "autonom")
                return;
            const state = store.getState();
            const focused = state?.acp?.focusedSessionId;
            if (typeof focused === "string" && focused.length > 0)
            {
                const sessionId = focused.includes("/") ? focused.split("/").pop()! : focused;
                if (sessionId && !registeredSessionIds.has(sessionId) && /^[a-z0-9_-]+$/i.test(sessionId))
                {
                    registeredSessionIds.add(sessionId);
                    void bridgeRequest({ action: "registerSession", id: sessionId }).catch(() => undefined);
                }
            }
        });
    }

    let overrideStyle: HTMLStyleElement | undefined;

    function updateOverrideStyles(): void
    {
        const document = globalThis.document;
        if (!document?.head)
            return;
        if (mode === "autonom" && content.enabled)
        {
            if (!overrideStyle || !overrideStyle.isConnected)
            {
                overrideStyle?.remove();
                overrideStyle = document.createElement("style");
                overrideStyle.id = "autonom-native-overrides";
                document.head.appendChild(overrideStyle);
            }
            overrideStyle.textContent = `
                div[class*="max-w-[200px]"] button[aria-haspopup="menu"] {
                    pointer-events: none !important;
                    cursor: default !important;
                }
                /* Custom session page cleanups: hide Switch agent location, Go to sessions list, and Recent sessions list */
                [data-beard-row="true"] button:first-child:not(:only-child) {
                    display: none !important;
                }
                [data-beard-row="true"] button:last-child:not(:only-child) {
                    display: none !important;
                }
                .windsurf-welcome-container .absolute.left-0.top-full {
                    display: none !important;
                }
            `;
        }
        else
        {
            overrideStyle?.remove();
            overrideStyle = undefined;
        }
    }

    let isSyncing = false;
    function syncAutonomDomState(): void
    {
        const document = globalThis.document;
        if (!document?.body || isSyncing)
            return;
        isSyncing = true;
        if (providerObserver)
            providerObserver.disconnect();
        try
        {
            updateOverrideStyles();
            renderProviderToggle();

            if (!keydownListenerAttached)
            {
                document.addEventListener("keydown", onKeyDown, true);
                keydownListenerAttached = true;
            }

            attachSessionWatcher();

            const aside = document.querySelector<HTMLElement>('aside[data-slot="sidebar"]');
            const asideChildren = aside ? (Array.from(aside.children) as HTMLElement[]) : [];
            const header = aside?.querySelector<HTMLElement>('[data-slot="sidebar-header"]');
            const footer = aside?.querySelector<HTMLElement>('[data-slot="sidebar-footer"]');
            const middle = asideChildren.find((child) => child.querySelector?.('[data-slot="sidebar-content-wrapper"]')
                || (!child.className?.includes("hidden") && child.className?.includes("min-h-0 flex-1")));

            if (mode === "autonom")
            {
                for (const child of asideChildren)
                {
                    if (child === header || child.contains(header || null) || child === middle
                        || child === footer || child.contains(footer || null))
                        child.style.display = "";
                    else
                        child.style.display = "none";
                }
                if (footer)
                    footer.style.display = "";

                for (const group of document.querySelectorAll<HTMLElement>('[data-slot="sidebar-group"]'))
                {
                    const label = group.textContent || "";
                    if (label.includes("Spaces") || label.includes("Split into new space")
                        || label.includes("ago") || label.includes("Session "))
                        group.style.display = "none";
                    else
                        group.style.display = "";
                }

                for (const item of aside?.querySelectorAll("li") || [])
                {
                    if (item.textContent?.trim() === "Sessions")
                        item.style.display = "none";
                }

                const scrollContent = aside?.querySelector<HTMLElement>('[data-slot="scroll-area-content"]');
                const navGroup = scrollContent?.querySelector<HTMLElement>('[data-slot="sidebar-group"]');
                if (scrollContent && navGroup)
                {
                    const profilesHeader = sectionHeader(document, scrollContent, "profiles", "Profiles");
                    if (profilesHeader.parentElement !== scrollContent || profilesHeader.previousElementSibling !== navGroup)
                        navGroup.after(profilesHeader);
                    profilesHeader.style.display = "";

                    const roomsHeader = sectionHeader(document, scrollContent, "rooms", "Rooms");
                    if (roomsHeader.parentElement !== scrollContent || roomsHeader.previousElementSibling !== profilesHeader)
                        profilesHeader.after(roomsHeader);
                    roomsHeader.style.display = "";
                }

                const newSessionBtn = document.querySelector<HTMLButtonElement>('button[aria-label="New session"]');
                if (newSessionBtn && !(newSessionBtn as any).__autonomHooked)
                {
                    (newSessionBtn as any).__autonomHooked = true;
                    newSessionBtn.addEventListener("click", () =>
                    {
                        if (mode === "autonom")
                        {
                            autonomPageVisible = false;
                            autonomActiveSurface = null;
                            for (const view of views.values())
                                view.host.style.display = "none";
                        }
                    }, true);
                }

                const devinLogo = document.querySelector<SVGSVGElement>(
                    ".windsurf-welcome-container svg.absolute.bottom-full:not([data-autonom-logo])");
                if (devinLogo)
                {
                    devinLogo.style.display = "none";
                    let autonomLogo = devinLogo.parentElement?.querySelector<SVGSVGElement>("svg[data-autonom-logo]");
                    if (!autonomLogo && devinLogo.parentElement)
                    {
                        autonomLogo = document.createElementNS("http://www.w3.org/2000/svg", "svg");
                        autonomLogo.dataset.autonomLogo = "true";
                        autonomLogo.setAttribute("class", "absolute bottom-full mb-6 text-text-primary opacity-10");
                        autonomLogo.setAttribute("aria-hidden", "true");
                        autonomLogo.setAttribute("width", "64px");
                        autonomLogo.setAttribute("height", "64px");
                        autonomLogo.setAttribute("viewBox", "0 0 48 48");
                        autonomLogo.setAttribute("fill", "currentColor");
                        const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
                        path.setAttribute("fill-rule", "evenodd");
                        path.setAttribute("clip-rule", "evenodd");
                        path.setAttribute("d", AUTONOM_FILL_PATH);
                        autonomLogo.appendChild(path);
                        devinLogo.parentElement.insertBefore(autonomLogo, devinLogo);
                    }
                    if (autonomLogo)
                        autonomLogo.style.display = "";
                }

                for (const button of document.querySelectorAll<HTMLButtonElement>("button"))
                {
                    if (button.classList.contains("switch-segment"))
                        continue;
                    const isAcpParent = button.parentElement?.className?.includes("max-w-[200px]");
                    const label = button.textContent?.trim() || "";
                    const isAcpText = ["Devin Local", "Codex", "OpenCode", "Antigravity (DBA)", "Devin Cloud"].includes(label);
                    if ((isAcpParent || isAcpText) && button.getAttribute("aria-haspopup") === "menu")
                    {
                        const span = button.querySelector("span");
                        if (span && span.textContent !== DEVIN_LOCAL)
                            span.textContent = DEVIN_LOCAL;
                        button.style.pointerEvents = "none";
                        button.style.cursor = "default";
                        button.setAttribute("data-disabled", "");
                        button.setAttribute("aria-disabled", "true");
                        button.tabIndex = -1;
                    }
                }

                for (const popup of document.querySelectorAll<HTMLElement>('[role="menu"], [data-slot="menu"], [class*="popup"]'))
                {
                    const label = popup.textContent || "";
                    if (label.includes("switch agents")
                        || (label.includes("Devin Local") && (label.includes("Codex") || label.includes("OpenCode"))))
                    {
                        popup.style.display = "none";
                        popup.remove();
                    }
                }
            }
            else
            {
                for (const child of asideChildren)
                    child.style.display = "";
                for (const group of document.querySelectorAll<HTMLElement>('[data-slot="sidebar-group"]'))
                    group.style.display = "";
                for (const header_ of document.querySelectorAll<HTMLElement>('[data-autonom-section]'))
                    header_.remove();
                if (footer)
                    footer.style.display = "";
                for (const item of aside?.querySelectorAll("li") || [])
                {
                    if (item.textContent?.trim() === "Sessions")
                        item.style.display = "";
                }
                const devinLogo = document.querySelector<SVGSVGElement>(
                    ".windsurf-welcome-container svg.absolute.bottom-full:not([data-autonom-logo])");
                if (devinLogo)
                    devinLogo.style.display = "";
                const autonomLogo = document.querySelector<SVGSVGElement>(
                    ".windsurf-welcome-container svg[data-autonom-logo]");
                if (autonomLogo)
                    autonomLogo.style.display = "none";
                for (const button of document.querySelectorAll<HTMLButtonElement>("button"))
                {
                    if (button.parentElement?.className?.includes("max-w-[200px]")
                        && button.getAttribute("aria-haspopup") === "menu")
                    {
                        button.style.pointerEvents = "";
                        button.style.cursor = "";
                        button.removeAttribute("data-disabled");
                        button.removeAttribute("aria-disabled");
                        button.tabIndex = 0;
                    }
                }
            }
        }
        finally
        {
            isSyncing = false;
            if (!providerObserver)
                providerObserver = new MutationObserver(() => syncAutonomDomState());
            providerObserver.observe(document.body, { childList: true, subtree: true });
        }
    }

    function sectionHeader(document: Document, scrollContent: HTMLElement, id: string, label: string): HTMLElement
    {
        let header = scrollContent.querySelector<HTMLElement>(`[data-autonom-section="${id}"]`);
        if (header)
            return header;
        header = document.createElement("div");
        header.dataset.slot = "sidebar-group";
        header.dataset.autonomSection = id;
        header.className = "relative flex w-full min-w-0 flex-col px-[--sidebar-padding] pb-1";
        const row = document.createElement("div");
        row.dataset.slot = "sidebar-label-row";
        row.className = "group/sidebar-label-row flex h-8 shrink-0 items-center justify-between gap-px pl-[--sidebar-content-button-x-padding] pr-1";
        const labelElement = document.createElement("div");
        labelElement.dataset.slot = "sidebar-group-label";
        labelElement.className = "text-12 text-text-secondary flex items-center rounded-md font-medium flex-1";
        labelElement.textContent = label;
        row.appendChild(labelElement);
        header.appendChild(row);
        return header;
    }

    wrap(manifest, "getManifest", effectiveManifest);
    const nativeNewAgentWindowSession = groups.newAgentWindowSession;
    if (typeof nativeNewAgentWindowSession === "function")
    {
        wrap(groups, "newAgentWindowSession", function (this: any, ...args: any[]): any
        {
            if (mode === "autonom")
            {
                autonomPageVisible = false;
                autonomActiveSurface = null;
                for (const view of views.values())
                    view.host.style.display = "none";
            }
            return nativeNewAgentWindowSession.apply(this, args);
        });
    }
    const subscription = manifest.onDidChangeManifest(() =>
    {
        if (relaying)
            return;
        cachedManifest = undefined;
        if (content.enabled && mode === "autonom")
            notify();
    });
    const show = controller.show;
    wrap(controller, "show", async function (this: any, surface: NativeItem): Promise<void>
    {
        if (render(this, surface))
            return;
        removeView(this);
        return show.call(this, surface);
    });
    for (const name of ["resetActiveSurface", "reloadActiveSurface", "_load", "_remountAndLoad"])
    {
        const original = controller[name];
        if (typeof original !== "function")
            continue;
        wrap(controller, name, function (this: any, ...arguments_: unknown[]): unknown
        {
            if (render(this, this._currentSurface))
                return Promise.resolve();
            return original.apply(this, arguments_);
        });
    }
    const setVisible = controller.setVisible;
    wrap(controller, "setVisible", function (this: any, visible: boolean): void
    {
        setVisible.call(this, visible);
        const view = views.get(this);
        if (view)
            view.host.style.display = visible ? "" : "none";
    });

    const runtime = {
        heartbeat(): void
        {
            if (lease !== undefined)
                clearTimeout(lease);
            lease = setTimeout(() => runtime.dispose(), LEASE_TIMEOUT);
        },
        status(): RuntimeStatus
        {
            const active = groups.getActiveNavSurface(windowId);
            return {
                connected: true,
                mode,
                enabled: content.enabled && mode === "autonom",
                revision: content.revision ?? null,
                activeTab: tabFor(active),
                windowId,
                items: effectiveManifest().items.map((item: NativeItem) =>
                {
                    return { id: item.id, label: item.label, path: item.path };
                }),
            };
        },
        async update(next: RuntimeConfig): Promise<RuntimeStatus>
        {
            if (!next?.content || !next.bridge?.url || !next.bridge?.token)
                throw new Error("The Command Center runtime needs content and a bridge endpoint.");
            overlayItems(getManifest.call(manifest).items, { ...next.content, enabled: next.content.enabled && mode === "autonom" });
            content = next.content;
            bridge = next.bridge;
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
            for (const view of [...views.values()])
            {
                if (tabFor(view.surface) && effective?.path === view.surface.path)
                    render(view.controller, view.surface);
                else
                    removeView(view.controller);
            }
            if (content.enabled && mode === "autonom" && content.activeTab)
                await runtime.open(content.activeTab);
            return runtime.status();
        },
        async open(tab: string): Promise<RuntimeStatus>
        {
            const item = effectiveManifest().items.find((item: NativeItem) => item.path === `/autonom/${tab}`);
            if (!content.enabled || mode !== "autonom" || !Object.hasOwn(content.tabs, tab) || !item)
                throw new Error(`Unknown or hidden custom tab: ${tab}`);
            await api.executeCommand("devin.desktopNav.openSurface", { id: item.id, path: item.path });
            return runtime.status();
        },
        async setMode(nextMode: "autonom" | "devin-cloud"): Promise<RuntimeStatus>
        {
            if (nextMode !== "autonom" && nextMode !== "devin-cloud")
                throw new Error("Unknown Command Center provider.");
            if (mode === nextMode)
                return runtime.status();
            const active = groups.getActiveNavSurface(windowId);
            const nativeItems = getManifest.call(manifest).items as NativeItem[];

            if (mode === "autonom")
            {
                autonomActiveSurface = (autonomPageVisible && active?.path?.startsWith("/autonom/"))
                    ? { id: active.id, path: active.path }
                    : null;
            }
            else
            {
                devinCloudActiveSurface = active ? { id: active.id, path: active.path } : null;
            }

            mode = nextMode;
            generation++;
            cachedManifest = undefined;
            notify();
            syncAutonomDomState();

            if (mode === "devin-cloud")
            {
                for (const instance of [...views.keys()])
                    removeView(instance);
                if (devinCloudActiveSurface)
                {
                    await api.executeCommand("devin.desktopNav.openSurface", {
                        id: devinCloudActiveSurface.id,
                        path: devinCloudActiveSurface.path,
                    }).catch(() =>
                    {
                        groups.setActiveNavSurface(windowId, devinCloudActiveSurface);
                    });
                }
                else if (active?.path?.startsWith("/autonom/"))
                {
                    const fallback = nativeItems.find((item) => item.id === active.id);
                    if (fallback)
                        groups.setActiveNavSurface(windowId, { id: fallback.id, path: fallback.path });
                    else
                    {
                        groups.setActiveNavSurface(windowId, null);
                        groups.newAgentWindowSession?.();
                    }
                }
                else
                {
                    groups.setActiveNavSurface(windowId, null);
                    groups.newAgentWindowSession?.();
                }
            }
            else
            {
                if (autonomActiveSurface && autonomActiveSurface.path.startsWith("/autonom/"))
                {
                    const tab = autonomActiveSurface.path.slice(9);
                    if (Object.hasOwn(content.tabs, tab))
                        await runtime.open(tab).catch(() => undefined);
                }
                else
                {
                    for (const view of views.values())
                        view.host.style.display = "none";
                    groups.setActiveNavSurface(windowId, null);
                    groups.newAgentWindowSession?.();
                }
            }
            return runtime.status();
        },
        dispose(): void
        {
            if (lease !== undefined)
                clearTimeout(lease);
            providerObserver?.disconnect();
            providerRow?.remove();
            if (keydownListenerAttached)
            {
                globalThis.document?.removeEventListener("keydown", onKeyDown, true);
                keydownListenerAttached = false;
            }
            if (acpStoreUnsubscribe)
            {
                acpStoreUnsubscribe();
                acpStoreUnsubscribe = undefined;
            }
            const aside = globalThis.document?.querySelector<HTMLElement>('aside[data-slot="sidebar"]');
            if (aside)
            {
                for (const child of Array.from(aside.children) as HTMLElement[])
                    child.style.display = "";
            }
            for (const group of globalThis.document?.querySelectorAll<HTMLElement>('[data-slot="sidebar-group"]') || [])
                group.style.display = "";
            for (const button of globalThis.document?.querySelectorAll<HTMLButtonElement>("button") || [])
            {
                if (button.parentElement?.className?.includes("max-w-[200px]")
                    && button.getAttribute("aria-haspopup") === "menu")
                {
                    button.style.pointerEvents = "";
                    button.style.cursor = "";
                    button.removeAttribute("data-disabled");
                    button.removeAttribute("aria-disabled");
                    button.tabIndex = 0;
                }
            }
            overrideStyle?.remove();
            overrideStyle = undefined;
            providerObserver = undefined;
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
            for (const saved of descriptors.reverse())
            {
                if (saved.object[saved.name] !== saved.wrapper)
                    continue;
                if (saved.descriptor)
                    Object.defineProperty(saved.object, saved.name, saved.descriptor);
                else
                    delete saved.object[saved.name];
            }
            const devinLogo = globalThis.document?.querySelector<SVGSVGElement>(
                ".windsurf-welcome-container svg.absolute.bottom-full:not([data-autonom-logo])");
            if (devinLogo)
                devinLogo.style.display = "";
            globalThis.document?.querySelector<SVGSVGElement>(".windsurf-welcome-container svg[data-autonom-logo]")?.remove();
            for (const header of globalThis.document?.querySelectorAll<HTMLElement>("[data-autonom-section]") || [])
                header.remove();
            if (active?.path?.startsWith("/autonom/"))
            {
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
