import autonomFillMarkup from "../../assets/icons/autonom-fill.svg";
import autonomLineMarkup from "../../assets/icons/autonom.svg";
import cloudFillMarkup from "../../assets/icons/cloud-fill.svg";
import cloudLineMarkup from "../../assets/icons/cloud.svg";
import pencilFillMarkup from "../../assets/icons/pencil-fill.svg";
import pencilLineMarkup from "../../assets/icons/pencil.svg";
import uiCss from "../../assets/ui.css";
import type { ActionSource, CenterContent, NativeItem, SidebarItem } from "./center";
import { declaredItems, isFullDocument, overlayItems, pageHtml } from "./center";

export type RuntimeConfig = {
    content: CenterContent;
    bridge: { url: string; token: string };
};

export type RuntimeStatus = {
    connected: boolean;
    mode: "autonom" | "devin-cloud";
    enabled: boolean;
    revision: string | null;
    activeItem: string | null;
    windowId: number;
    editorActive: boolean;
    items: { id: string; label: string; path: string }[];
    sections: { id: string; label: string | null; items: string[] }[];
    loadedActions: number;
    compiledScripts: number;
};

type CustomView = {
    host: HTMLElement;
    webview: any;
    surface: NativeItem;
    html: string;
    nativeVisibility: string;
    routeDescriptor: PropertyDescriptor | undefined;
    routeWrapper: Function;
    nativeSurfaceId: unknown;
    nativeTitle: unknown;
    nativeSidebar: unknown;
    nativeCurrentSurface: unknown;
    stacks: Map<string, unknown>;
    lifetime: { dispose(): void };
};

const LEASE_TIMEOUT = 30000;

type Mode = "autonom" | "devin-cloud" | "editor";

function iconSet(lineMarkup: string, fillMarkup: string): { viewBox: string; line: string; fill: string }
{
    return {
        viewBox: /viewBox="([^"]+)"/.exec(lineMarkup)?.[1] ?? "0 0 16 16",
        line: /[\s]d="([^"]+)"/.exec(lineMarkup)?.[1] ?? "",
        fill: /[\s]d="([^"]+)"/.exec(fillMarkup)?.[1] ?? "",
    };
}

const ICONS: Record<Mode, { viewBox: string; line: string; fill: string }> = {
    autonom: iconSet(autonomLineMarkup, autonomFillMarkup),
    "devin-cloud": iconSet(cloudLineMarkup, cloudFillMarkup),
    editor: iconSet(pencilLineMarkup, pencilFillMarkup),
};

export function prepareShell(css = uiCss): any
{
    const target = globalThis as any;
    if (target.__autonomShell)
    {
        target.__autonomShell.update(css);
        target.__autonomShell.heartbeat();
        return target.__autonomShell;
    }

    const style = document.createElement("style");
    style.textContent = css;
    document.head.appendChild(style);
    const switches = new Map<HTMLElement, {
        host: HTMLElement;
        display: string;
        agent: HTMLButtonElement;
        editor: HTMLButtonElement;
    }>();
    let requested: "autonom" | "devin-cloud" = "autonom";
    let lease: ReturnType<typeof setTimeout> | undefined;
    let frame: ReturnType<typeof setTimeout> | undefined;
    let disposed = false;
    const observer = new MutationObserver(() =>
    {
        frame ??= setTimeout(() =>
        {
            frame = undefined;
            render();
        });
    });

    function render(): void
    {
        if (disposed)
            return;

        observer.disconnect();
        for (const [root, entry] of switches)
        {
            if (root.isConnected && entry.host.isConnected)
                continue;

            root.style.display = entry.display;
            entry.host.remove();
            switches.delete(root);
        }

        for (const root of document.querySelectorAll<HTMLElement>(".agent-editor-switch"))
        {
            const agent = root.querySelector<HTMLButtonElement>('button[aria-label="Agent"]');
            const editor = root.querySelector<HTMLButtonElement>('button[aria-label="Editor"]');
            if (!agent || !editor || !root.parentElement)
                continue;

            let entry = switches.get(root);
            if (entry && (entry.agent !== agent || entry.editor !== editor))
            {
                root.style.display = entry.display;
                entry.host.remove();
                switches.delete(root);
                entry = undefined;
            }

            if (!entry)
            {
                const host = document.createElement("div");
                host.dataset.autonomModeSwitch = "true";
                host.setAttribute("role", "group");
                host.setAttribute("aria-label", "Workspace mode");
                for (const [mode, label] of [
                    ["autonom", "Autonom"],
                    ["devin-cloud", "Devin Cloud"],
                    ["editor", "Editor"],
                ] as const)
                {
                    const button = document.createElement("button");
                    button.type = "button";
                    button.dataset.autonomMode = mode;
                    button.setAttribute("aria-label", label);
                    button.title = label;
                    const icon = ICONS[mode];
                    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
                    svg.setAttribute("viewBox", icon.viewBox);
                    svg.setAttribute("aria-hidden", "true");
                    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
                    path.setAttribute("fill-rule", "evenodd");
                    path.setAttribute("d", icon.line);
                    svg.appendChild(path);
                    button.appendChild(svg);
                    button.addEventListener("click", () =>
                    {
                        const restore = switches.get(root)?.display ?? "";
                        root.style.display = restore;
                        const nativeAgent = root.querySelector<HTMLButtonElement>('button[aria-label="Agent"]');
                        const nativeEditor = root.querySelector<HTMLButtonElement>('button[aria-label="Editor"]');
                        if (mode === "editor")
                        {
                            nativeEditor?.click();
                            setTimeout(() =>
                            {
                                root.style.display = "none";
                                if (!shell.editorActive())
                                    void target.__autonomCenter?.toggleEditor()
                                        .catch((error: Error) => console.error("[autonom]", error));

                                render();
                            }, 150);
                            return;
                        }

                        requested = mode;
                        if (nativeEditor?.getAttribute("aria-pressed") === "true")
                            nativeAgent?.click();

                        void target.__autonomCenter?.setMode(mode)
                            .catch((error: Error) => console.error("[autonom]", error));
                        root.style.display = "none";
                        render();
                    });
                    host.appendChild(button);
                }

                entry = { host, agent, editor, display: root.style.display };
                switches.set(root, entry);
                root.after(host);
                root.style.display = "none";
            }

            const mode = editor.getAttribute("aria-pressed") === "true" ? "editor"
                : target.__autonomCenter?.status().mode ?? requested;
            for (const button of entry.host.querySelectorAll<HTMLButtonElement>("button"))
            {
                const active = button.dataset.autonomMode === mode;
                button.setAttribute("aria-pressed", String(active));
                const icon = ICONS[button.dataset.autonomMode as Mode];
                const path = button.querySelector("path");
                if (!icon || !path)
                    continue;

                const d = active ? icon.fill : icon.line;
                if (path.getAttribute("d") !== d)
                    path.setAttribute("d", d);
            }
        }

        observer.observe(document.body, { childList: true, subtree: true, attributes: true,
            attributeFilter: ["aria-pressed"] });
    }

    const shell = {
        requestedMode(): "autonom" | "devin-cloud"
        {
            return requested;
        },
        editorActive(): boolean
        {
            return [...switches].filter(([, entry]) => entry.host.getBoundingClientRect().width > 0)
                .some(([root]) => root.querySelector('button[aria-label="Editor"]')?.getAttribute("aria-pressed") === "true");
        },
        update(nextCss: string): void
        {
            if (style.textContent !== nextCss)
                style.textContent = nextCss;

            render();
        },
        heartbeat(): void
        {
            clearTimeout(lease);
            lease = setTimeout(() => shell.dispose(), LEASE_TIMEOUT);
            render();
        },
        dispose(): void
        {
            if (disposed)
                return;

            disposed = true;
            clearTimeout(lease);
            if (frame !== undefined)
                clearTimeout(frame);

            observer.disconnect();
            for (const [root, entry] of switches)
            {
                root.style.display = entry.display;
                entry.host.remove();
            }

            style.remove();
            if (target.__autonomShell === shell)
                delete target.__autonomShell;
        },
    };
    target.__autonomShell = shell;
    shell.heartbeat();
    render();
    return shell;
}

/** `install` binds the runtime to one window; `update` applies a configuration. */
export function install(services: any, config: RuntimeConfig): any
{
    const target = globalThis as any;
    const { manifest, groups, controller, api, windowId } = services;
    if (!manifest?.getManifest || !manifest?._onDidChangeManifest?.fire || !manifest.onDidChangeManifest
        || !groups?.setActiveNavSurface || !groups?.getActiveNavSurface || !api?.executeCommand
        || !Number.isInteger(windowId) || !controller?.show || !controller?.setVisible
        || !controller?.resetActiveSurface || !controller?.reloadActiveSurface || !controller?._load)
        throw new Error("Unsupported native Command Center service shape.");

    if (!config?.content || !config.bridge?.url || !config.bridge?.token)
        throw new Error("The Command Center runtime needs content and a bridge endpoint.");

    const replacing = Boolean(target.__autonomCenter);
    const previousMode = target.__autonomCenter?.status().mode;
    const previousNavigation = target.__autonomCenter?.navigationState?.();
    const previousSurface = groups.getActiveNavSurface(windowId);
    const requestedMode = target.__autonomShell?.requestedMode() ?? "autonom";
    target.__autonomCenter?.dispose();
    let content: CenterContent = { enabled: false, sections: [] };
    let bridge = config.bridge;
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
    let observer: MutationObserver | undefined;

    const descriptors: { object: any; name: string; descriptor: PropertyDescriptor | undefined; wrapper: Function }[] = [];
    const views = new Map<any, CustomView>();
    const getManifest = manifest.getManifest;
    let items = new Map<string, SidebarItem>();
    const sources = new Map<string, ActionSource>();
    const requests = new Map<string, Promise<ActionSource>>();
    const scripts = new Map<string, { version: string; run: (context: any) => Promise<unknown> }>();
    const headers = new Map<HTMLUListElement, Map<string, HTMLLIElement>>();
    const running = new Set<string>();
    let observerFrame: ReturnType<typeof setTimeout> | undefined;
    let navigation = 0;

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

    function wrap(object: any, name: string, wrapper: Function): void
    {
        descriptors.push({ object, name, descriptor: Object.getOwnPropertyDescriptor(object, name), wrapper });
        Object.defineProperty(object, name, { configurable: true, writable: true, value: wrapper });
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

    function actionKey(item: SidebarItem): string
    {
        const action = item.actions!.left_click;
        return `${action.file}:${action.version}`;
    }

    async function loadPage(item: SidebarItem, revision = content.revision): Promise<ActionSource>
    {
        const key = actionKey(item);
        let request = requests.get(key);
        if (!request)
        {
            request = bridgeRequest({ action: "getAction", id: item.id, revision }).then((value) =>
            {
                if (value?.type !== "html" || typeof value.source !== "string")
                    throw new Error("The UI action did not return HTML.");

                if (!disposed && requests.get(key) === request)
                    sources.set(key, value);
                return value as ActionSource;
            });
            requests.set(key, request);
        }

        try
        {
            return await request;
        }
        catch (error)
        {
            if (requests.get(key) === request)
                requests.delete(key);

            throw error;
        }
    }

    async function bridgeRequest(message: Record<string, unknown>): Promise<any>
    {
        const response = await fetch(`${bridge.url}/request`, {
            method: "POST",
            headers: { "content-type": "application/json", "x-autonom-bridge": bridge.token },
            body: JSON.stringify({ ...message, windowId }),
            signal: AbortSignal.timeout(30000),
        });
        const body = await response.json();
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
        const shell = instance._webview;
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
        instance._currentSurface = view.nativeCurrentSurface;
        instance._loadedSurfaceId = undefined;
        shell._reportState();
        instance._store?.delete(view.lifetime);
        view.lifetime.dispose();
        view.webview.dispose();
        view.host.remove();
    }

    function render(instance: any, surface: NativeItem, visible = true): boolean
    {
        const item = itemFor(surface);
        if (!item)
            return false;

        const source = sources.get(actionKey(item));
        if (!source)
            throw new Error("The HTML action is not loaded yet.");

        const page = { title: item.label ?? item.id, html: source.source };
        const shell = instance._webview;
        if (!shell?._hostEl || !shell?._mountEl || !shell?._webviewService?.createWebviewElement
            || !shell?._surfaces || !shell?._reportState || !instance._register)
            throw new Error("Native page host is not ready.");

        let view = views.get(instance);
        if (!view || !view.host.isConnected)
        {
            removeView(instance);
            const host = shell._hostEl.ownerDocument.createElement("div") as HTMLElement;
            host.dataset.autonomCenter = "page";
            shell._hostEl.appendChild(host);
            const webview = shell._webviewService.createWebviewElement({
                title: page.title,
                options: { retainContextWhenHidden: true, enableFindWidget: true },
                contentOptions: {
                    enableScripts: true,
                    allowScripts: true,
                    enableForms: true,
                    allowForms: true,
                    localResourceRoots: [],
                },
                extension: undefined,
            });
            try
            {
                webview.mountTo(host, shell._hostEl.ownerDocument.defaultView);
            }
            catch (error)
            {
                webview.dispose();
                host.remove();
                throw error;
            }

            const messageSub = webview.onMessage?.(async (event: any) =>
            {
                const message = event?.message ?? event;
                const reqId = message?.reqId ?? message?.id;
                if (typeof reqId !== "string" && typeof reqId !== "number")
                    return;

                try
                {
                    webview.postMessage({ reqId, id: reqId, result: await bridgeRequest(message) });
                }
                catch (error)
                {
                    webview.postMessage({ reqId, id: reqId, error: error instanceof Error ? error.message : String(error) });
                }
            });
            view = {
                host,
                webview,
                surface,
                html: "",
                nativeVisibility: shell._mountEl.style.visibility,
                routeDescriptor: Object.getOwnPropertyDescriptor(shell, "_onActiveRoute"),
                routeWrapper: function (): void
                {
                    return;
                },
                nativeSurfaceId: shell._activeSurfaceId,
                nativeTitle: shell._title,
                nativeSidebar: shell._activeSidebar,
                nativeCurrentSurface: instance._currentSurface,
                stacks: new Map(),
                lifetime: {
                    dispose(): void
                    {
                        messageSub?.dispose();
                        removeView(instance);
                    },
                },
            };
            views.set(instance, view);
            shell._onActiveRoute = view.routeWrapper;
            instance._register(view.lifetime);
        }

        const html = isFullDocument(page.html) ? page.html : pageHtml(page);
        if (view.html !== html)
        {
            view.webview.setHtml(html);
            view.html = html;
        }

        view.surface = surface;
        view.host.dataset.autonomItem = item.id;
        view.host.hidden = !visible;
        shell._mountEl.style.visibility = "hidden";
        instance._currentSurface = surface;
        shell._activeSurfaceId = surface.id;
        if (!view.stacks.has(surface.id))
            view.stacks.set(surface.id, shell._surfaces.get(surface.id));

        shell._surfaces.set(surface.id, { stack: [surface.path], cursor: 0, lastRouteCategory: undefined });
        shell._title = page.title;
        shell._activeSidebar = undefined;
        shell._reportState();
        instance.setVisible(visible);
        return true;
    }

    async function renderLoaded(instance: any, surface: NativeItem): Promise<boolean>
    {
        const item = itemFor(surface);
        if (!item)
            return false;

        const key = actionKey(item);
        await loadPage(item);
        const current = itemFor(surface);
        if (disposed || !current || actionKey(current) !== key)
            return true;

        return render(instance, surface);
    }

    function renderLayout(): void
    {
        if (!globalThis.document?.body || disposed)
            return;

        observer?.disconnect();
        try
        {
            prepareShell(content.css ?? uiCss);
            renderSections();
        }
        finally
        {
            observer ??= new MutationObserver(() =>
            {
                observerFrame ??= setTimeout(() =>
                {
                    observerFrame = undefined;
                    renderLayout();
                });
            });
            observer.observe(document.body, { childList: true, subtree: true });
        }
    }

    function nativeItemId(button: HTMLElement): string | undefined
    {
        const key = Object.keys(button).find((name) => name.startsWith("__reactFiber$"));
        let fiber = key ? (button as any)[key] : null;
        for (let index = 0; fiber && index < 128; index++, fiber = fiber.return)
        {
            const id = fiber.memoizedProps?.tab;
            if (typeof id === "string" && items.has(id))
                return id;
        }

        return undefined;
    }

    function renderSections(): void
    {
        const menus = new Set(document.querySelectorAll<HTMLUListElement>('ul[aria-label="Pages"]'));
        for (const [menu, sectionHeaders] of headers)
        {
            if (menus.has(menu) && content.enabled && mode === "autonom")
                continue;

            for (const header of sectionHeaders.values())
                header.remove();

            headers.delete(menu);
        }

        for (const button of document.querySelectorAll<HTMLElement>("button[data-autonom-item]"))
            if (!content.enabled || mode !== "autonom" || !items.has(button.dataset.autonomItem!))
                delete button.dataset.autonomItem;

        if (!content.enabled || mode !== "autonom")
            return;

        for (const menu of menus)
        {
            const rows = new Map<string, HTMLElement>();
            for (const row of Array.from(menu.children) as HTMLElement[])
            {
                const button = row.querySelector<HTMLElement>('[data-slot="sidebar-menu-button"] > button[aria-label]');
                const id = button && nativeItemId(button);
                if (!id || !button)
                    continue;

                button.dataset.autonomItem = id;
                rows.set(id, row);
            }

            let sectionHeaders = headers.get(menu);
            if (!sectionHeaders)
            {
                sectionHeaders = new Map();
                headers.set(menu, sectionHeaders);
            }

            const displayed = new Set<string>();
            let anchor: HTMLElement | null = null;
            for (let index = content.sections.length - 1; index >= 0; index--)
            {
                const section = content.sections[index]!;
                anchor = section.items.map((item) => rows.get(item.id)).find(Boolean) ?? anchor;
                if (!section.label || section.items.length > 0 && section.items.every((item) => item.hidden))
                    continue;

                displayed.add(section.id);
                let header = sectionHeaders.get(section.id);
                if (!header)
                {
                    header = document.createElement("li");
                    header.dataset.autonomSection = section.id;
                    header.setAttribute("role", "presentation");
                    const label = document.createElement("h2");
                    header.appendChild(label);
                    sectionHeaders.set(section.id, header);
                }

                if (header.firstElementChild!.textContent !== section.label)
                    header.firstElementChild!.textContent = section.label;

                if (header.parentElement !== menu || header.nextElementSibling !== anchor)
                    menu.insertBefore(header, anchor);

                anchor = header;
            }

            for (const [id, header] of sectionHeaders)
            {
                if (displayed.has(id))
                    continue;

                header.remove();
                sectionHeaders.delete(id);
            }
        }
    }

    function onClick(event: MouseEvent): void
    {
        if (!content.enabled || mode !== "autonom" || event.button !== 0)
            return;

        const button = (event.target as Element | null)?.closest<HTMLButtonElement>("button[data-autonom-item]");
        const id = button?.dataset.autonomItem;
        if (!button || !id || !items.get(id)?.actions?.left_click)
            return;

        event.preventDefault();
        event.stopImmediatePropagation();
        button.setAttribute("aria-busy", "true");
        void runtime.activate(id).catch((error) =>
        {
            button.title = error instanceof Error ? error.message : String(error);
            console.error("[autonom]", error);
        }).finally(() => button.removeAttribute("aria-busy"));
    }

    globalThis.document?.addEventListener("click", onClick, true);
    wrap(manifest, "getManifest", effectiveManifest);
    const subscription = manifest.onDidChangeManifest(() =>
    {
        if (notifying)
            return;

        cachedManifest = undefined;
        if (content.enabled && mode === "autonom")
            notify();
    });
    const show = controller.show;
    wrap(controller, "show", async function (this: any, surface: NativeItem): Promise<void>
    {
        if (await renderLoaded(this, surface))
            return;

        removeView(this);
        return show.call(this, surface);
    });
    for (const name of ["resetActiveSurface", "reloadActiveSurface", "_load", "_remountAndLoad"])
    {
        const original = controller[name];
        if (typeof original !== "function")
            continue;

        wrap(controller, name, async function (this: any, ...args: unknown[]): Promise<unknown>
        {
            if (await renderLoaded(this, this._currentSurface))
                return;

            return original.apply(this, args);
        });
    }

    const setVisible = controller.setVisible;
    wrap(controller, "setVisible", function (this: any, visible: boolean): void
    {
        setVisible.call(this, visible);
        const view = views.get(this);
        if (view)
            view.host.hidden = !visible;
    });

    const runtime = {
        heartbeat(): void
        {
            if (disposed)
                return;

            clearTimeout(lease);
            lease = setTimeout(() => runtime.dispose(), LEASE_TIMEOUT);
        },
        status(): RuntimeStatus
        {
            return {
                connected: !disposed,
                mode,
                enabled: content.enabled && mode === "autonom",
                revision: content.revision ?? null,
                activeItem: itemFor(groups.getActiveNavSurface(windowId))?.id ?? null,
                windowId,
                editorActive: target.__autonomShell?.editorActive() ?? false,
                items: effectiveManifest().items.map((item: NativeItem) =>
                {
                    return { id: item.id, label: item.label, path: item.path };
                }),
                sections: content.sections.map((section) => ({
                    id: section.id,
                    label: section.label ?? null,
                    items: section.items.filter((item) => !item.hidden).map((item) => item.id),
                })),
                loadedActions: sources.size + scripts.size,
                compiledScripts: scripts.size,
            };
        },
        navigationState(): unknown
        {
            return { autonom: savedAutonomSurface, native: savedNativeSurface };
        },
        async update(next: RuntimeConfig): Promise<RuntimeStatus>
        {
            if (disposed)
                throw new Error("The UI runtime is disposed.");

            if (!next?.content || !next.bridge?.url || !next.bridge?.token)
                throw new Error("The Command Center runtime needs content and a bridge endpoint.");

            overlayItems(getManifest.call(manifest).items, next.content);
            const nextItems = new Map(declaredItems(next.content).map((item) => [item.id, item]));
            const active = groups.getActiveNavSurface(windowId);
            const initial = !initialized && !target.__autonomShell?.editorActive()
                ? nextItems.get(previousSurface?.id)?.id ?? (!replacing ? next.content.activeItem : undefined) : undefined;
            const selectedIds = new Set([active?.id, initial, ...[...views.values()].map((view) => view.surface.id)]);
            if (next.content.enabled && mode === "autonom")
            {
                for (const id of selectedIds)
                {
                    const selected = nextItems.get(id);
                    if (selected?.actions?.left_click.type === "html")
                        await loadPage(selected, next.content.revision);
                }
            }

            if (disposed)
                throw new Error("The UI runtime is disposed.");

            navigation++;
            content = next.content;
            items = nextItems;
            const keys = new Set([...items.values()].filter((item) => item.actions).map(actionKey));
            for (const key of requests.keys())
            {
                if (keys.has(key))
                    continue;

                requests.delete(key);
                sources.delete(key);
            }

            for (const key of scripts.keys())
                if (!keys.has(key))
                    scripts.delete(key);

            bridge = next.bridge;
            if (!content.enabled)
                mode = "devin-cloud";

            generation++;
            cachedManifest = undefined;
            notify();
            renderLayout();
            const item = effectiveManifest().items.find((entry: NativeItem) => entry.id === active?.id);
            if (active && (!item || item.path !== active.path))
                groups.setActiveNavSurface(windowId, item ? { id: item.id, path: item.path } : null);

            for (const [instance, view] of views)
            {
                const selected = itemFor(view.surface);
                if (selected)
                    render(instance, view.surface, !view.host.hidden);
                else
                    removeView(instance);
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
            await loadPage(item);
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
                    await bridgeRequest({ action: "runScript", id, revision: content.revision });
            }
            finally
            {
                running.delete(id);
            }
        },
        hasScript(id: string, version: string): boolean
        {
            const item = items.get(id);
            return item?.actions?.left_click.type === "js" && item.actions.left_click.version === version
                && scripts.get(actionKey(item))?.version === version;
        },
        async toggleEditor(): Promise<void>
        {
            await api.executeCommand("devin.webapp.toggleAgentWindow");
        },
        setScript(id: string, version: string, run: (context: any) => Promise<unknown>): void
        {
            const action = items.get(id)?.actions?.left_click;
            if (disposed || action?.type !== "js" || action.version !== version)
                throw new Error("The JS action changed before compilation.");

            scripts.set(actionKey(items.get(id)!), { version, run });
        },
        async runScript(id: string, version: string): Promise<void>
        {
            const item = items.get(id);
            const script = item?.actions?.left_click.type === "js" ? scripts.get(actionKey(item)) : undefined;
            if (disposed || !content.enabled || mode !== "autonom" || !script || script.version !== version)
                throw new Error("The JS action is not available in this UI snapshot.");

            await script.run(Object.freeze({
                item: Object.freeze({ id, label: items.get(id)?.label ?? id }),
                request: bridgeRequest,
                open: (itemId: string) => runtime.open(itemId),
                executeCommand: (command: string, ...args: unknown[]) => api.executeCommand(command, ...args),
                refresh: () => bridgeRequest({ action: "reloadUi" }),
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
            renderLayout();
            for (const instance of views.keys())
                removeView(instance);

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
            observer?.disconnect();
            if (observerFrame !== undefined)
                clearTimeout(observerFrame);

            globalThis.document?.removeEventListener("click", onClick, true);
            target.__autonomShell?.dispose();
            for (const sectionHeaders of headers.values())
                for (const header of sectionHeaders.values())
                    header.remove();

            for (const button of globalThis.document?.querySelectorAll<HTMLElement>("button[data-autonom-item]") ?? [])
                delete button.dataset.autonomItem;

            requests.clear();
            sources.clear();
            scripts.clear();
            const active = groups.getActiveNavSurface(windowId);
            content = { enabled: false, sections: [] };
            mode = "devin-cloud";
            for (const instance of views.keys())
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
