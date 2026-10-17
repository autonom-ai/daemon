import type { ActionStore } from "./actions";
import { actionKey } from "./actions";
import type { NativeItem, SidebarItem } from "./content";
import { isFullDocument, pageHtml } from "./content";

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


export function createPageViews(
    itemFor: (surface: any) => SidebarItem | undefined,
    actions: ActionStore,
    revision: () => string | undefined,
    isDisposed: () => boolean,
): {
    all: Map<any, CustomView>;
    remove: (instance: any) => void;
    render: (instance: any, surface: NativeItem, visible?: boolean) => boolean;
    renderLoaded: (instance: any, surface: NativeItem) => Promise<boolean>;
}
{
    const views = new Map<any, CustomView>();
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

        const source = actions.sources.get(actionKey(item));
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
                    webview.postMessage({ reqId, id: reqId, result: await actions.request(message) });
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
        await actions.loadPage(item, revision());
        const current = itemFor(surface);
        if (isDisposed() || !current || actionKey(current) !== key)
            return true;

        return render(instance, surface);
    }

    return { all: views, remove: removeView, render, renderLoaded };
}
