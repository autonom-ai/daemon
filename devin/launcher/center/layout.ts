import uiCss from "../../../assets/ui.css";
import type { CenterContent, SidebarItem } from "./content";
import { prepareShell } from "./shell";

export function createLayout(context: {
    readonly content: CenterContent;
    readonly items: Map<string, SidebarItem>;
    readonly enabled: boolean;
    activate: (id: string) => Promise<void>;
}): { render(): void; dispose(): void }
{
    const headers = new Map<HTMLUListElement, Map<string, HTMLLIElement>>();
    let disposed = false;
    let observer: MutationObserver | undefined;
    let observerFrame: ReturnType<typeof setTimeout> | undefined;

    function renderLayout(): void
    {
        if (!globalThis.document?.body || disposed)
            return;

        observer?.disconnect();
        try
        {
            prepareShell(context.content.css ?? uiCss);
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
        const items = context.items;
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
        const { content, items, enabled } = context;
        const menus = new Set(document.querySelectorAll<HTMLUListElement>('ul[aria-label="Pages"]'));
        for (const [menu, sectionHeaders] of headers)
        {
            if (menus.has(menu) && enabled)
                continue;

            for (const header of sectionHeaders.values())
                header.remove();

            headers.delete(menu);
        }

        for (const button of document.querySelectorAll<HTMLElement>("button[data-autonom-item]"))
            if (!enabled || !items.has(button.dataset.autonomItem!))
                delete button.dataset.autonomItem;

        if (!enabled)
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
        const { items, enabled } = context;
        if (!enabled || event.button !== 0)
            return;

        const button = (event.target as Element | null)?.closest<HTMLButtonElement>("button[data-autonom-item]");
        const id = button?.dataset.autonomItem;
        if (!button || !id || !items.get(id)?.actions?.left_click)
            return;

        event.preventDefault();
        event.stopImmediatePropagation();
        button.setAttribute("aria-busy", "true");
        void context.activate(id).catch((error) =>
        {
            button.title = error instanceof Error ? error.message : String(error);
            console.error("[autonom]", error);
        }).finally(() => button.removeAttribute("aria-busy"));
    }

    globalThis.document?.addEventListener("click", onClick, true);
    return {
        render: renderLayout,
        dispose(): void
        {
            disposed = true;
            observer?.disconnect();
            if (observerFrame !== undefined)
                clearTimeout(observerFrame);

            globalThis.document?.removeEventListener("click", onClick, true);
            for (const sectionHeaders of headers.values())
                for (const header of sectionHeaders.values())
                    header.remove();

            for (const button of globalThis.document?.querySelectorAll<HTMLElement>("button[data-autonom-item]") ?? [])
                delete button.dataset.autonomItem;
        },
    };
}
