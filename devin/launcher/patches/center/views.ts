import { Patches, restorePatches } from "../lifecycle";
import { createPatch } from "../status";
import { NativeHistory } from "./history";
import type { ActionStore } from "../../center/actions";
import { actionKey } from "../../center/actions";
import type { NativeItem, SidebarItem } from "../../center/content";
import { isFullDocument, pageHtml } from "../../center/content";

type CustomView = {
    host: HTMLElement;
    webview: any;
    surface: NativeItem;
    html: string;
    patches: Patches;
    history: NativeHistory;
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
    dispose(): void;
}
{
    const views = new Map<any, CustomView>();
    const navigation = new WeakMap<object, number>();
    const owner = createPatch("command-center.pages");
    let disposed = false;
    owner.cleanup(() =>
    {
        try
        {
            return restorePatches([...views.values()].map((view) => view.patches));
        }
        finally
        {
            views.clear();
        }
    });

    function advance(instance: object): number
    {
        const ret = (navigation.get(instance) ?? 0) + 1;
        navigation.set(instance, ret);
        return ret;
    }

    function removeView(instance: any): void
    {
        advance(instance);
        const view = views.get(instance);
        views.delete(instance);
        view?.patches.restore();
    }

    function createView(instance: any, surface: NativeItem, title: string): CustomView
    {
        const patches = new Patches("command-center.page");
        const shell = instance._webview;
        let live = true;
        patches.cleanup(() => { live = false; });
        try
        {
            const host = shell._hostEl.ownerDocument.createElement("div") as HTMLElement;
            patches.cleanup(() => host.remove());
            host.dataset.autonomCenter = "page";
            shell._hostEl.appendChild(host);
            const webview = shell._webviewService.createWebviewElement({
                title,
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
            patches.cleanup(() => webview.dispose());
            webview.mountTo(host, shell._hostEl.ownerDocument.defaultView);
            const messageSub = webview.onMessage?.(async (event: any) =>
            {
                const message = event?.message ?? event;
                const reqId = message?.reqId ?? message?.id;
                if (!live || disposed || isDisposed() || typeof reqId !== "string" && typeof reqId !== "number")
                    return;

                try
                {
                    const result = await actions.request(message);
                    if (live && !disposed && !isDisposed())
                        webview.postMessage({ reqId, id: reqId, result });
                }
                catch (error)
                {
                    if (live && !disposed && !isDisposed())
                        webview.postMessage({ reqId, id: reqId, error: error instanceof Error ? error.message : String(error) });
                }
            });
            patches.cleanup(() => messageSub?.dispose());
            const lifetime = { dispose: () => removeView(instance) };
            patches.cleanup(() => instance._store?.delete(lifetime));
            const history = new NativeHistory(shell);
            patches.cleanup(() => history.restore());
            const ret = { host, webview, surface, html: "", patches, history };
            patches.cleanup(() =>
            {
                if (views.get(instance) === ret)
                    views.delete(instance);
            });
            views.set(instance, ret);
            instance._register(lifetime);
            return ret;
        }
        catch (error)
        {
            live = false;
            patches.restore();
            throw error;
        }
    }

    function render(instance: any, surface: NativeItem, visible = true): boolean
    {
        advance(instance);
        const item = itemFor(surface);
        if (disposed || isDisposed() || !item)
            return false;

        const source = actions.sources.get(actionKey(item));
        if (!source)
            throw new Error("The HTML action is not loaded yet.");

        const page = { title: item.label ?? item.id, html: source.source };
        const shell = instance._webview;
        if (!shell?._hostEl || !shell?._mountEl || !shell?._webviewService?.createWebviewElement
            || !shell?._surfaces || !shell?._reportState || !instance._register)
            throw new Error("Native page host is not ready.");

        try
        {
            let view = views.get(instance);
            if (!view || !view.host.isConnected)
            {
                removeView(instance);
                view = createView(instance, surface, page.title);
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
            view.history.show(surface, page.title);
            instance.setVisible(visible);
            return true;
        }
        catch (error)
        {
            removeView(instance);
            throw error;
        }
    }

    async function renderLoaded(instance: any, surface: NativeItem): Promise<boolean>
    {
        const pending = advance(instance);
        const item = itemFor(surface);
        if (!item)
            return false;

        const key = actionKey(item);
        await actions.loadPage(item, revision());
        const current = itemFor(surface);
        if (disposed || isDisposed() || navigation.get(instance) !== pending || !current || actionKey(current) !== key)
            return true;

        return render(instance, surface);
    }

    return {
        all: views, remove: removeView, render, renderLoaded,
        dispose(): void
        {
            disposed = true;
            owner.restore();
        },
    };
}
