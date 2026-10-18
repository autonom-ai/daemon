import type { CdpSession } from "../cdp/client";

export async function watchSidebar(session: CdpSession, ready: () => void): Promise<() => Promise<void>>
{
    const name = "__autonomSidebarReady";
    const remove = session.on("Runtime.bindingCalled", (parameters) =>
    {
        if (parameters.name === name)
            ready();
    });
    await session.request("Runtime.enable");
    await session.request("Runtime.addBinding", { name });
    await session.evaluate(`(() => {
        let previous;
        const check = () => {
            const current = document.querySelector('[data-slot="sidebar-menu"]');
            if (current && current !== previous) globalThis.${name}("");
            previous = current;
        };
        const observer = new MutationObserver(check);
        observer.observe(document, {childList:true, subtree:true});
        globalThis.__autonomSidebarWatch = observer;
        check();
    })()`);
    return async () =>
    {
        remove();
        await session.evaluate("globalThis.__autonomSidebarWatch?.disconnect();delete globalThis.__autonomSidebarWatch")
            .catch(() => undefined);
        await session.request("Runtime.removeBinding", { name }).catch(() => undefined);
        await session.request("Runtime.disable").catch(() => undefined);
    };
}
