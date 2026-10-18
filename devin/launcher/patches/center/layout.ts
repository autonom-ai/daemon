import uiCss from "../../../../assets/ui.css";
import type { CenterContent, SidebarItem } from "../../center/content";
import { spacesSection } from "../../center/content";
import type { Directory } from "../../center/directory";
import { Patches, restorePatches } from "../lifecycle";
import { createPatch } from "../status";
import { Sidebar } from "./sidebar";
import { createSections } from "./sections";
import { prepareShell } from "../mode-switch";

export function createLayout(context: {
    readonly content: CenterContent;
    readonly items: Map<string, SidebarItem>;
    readonly enabled: boolean;
    readonly directory?: Directory;
    activate: (id: string) => Promise<void>;
}): { render(): void; dispose(): void }
{
    const sections = createSections(context.directory);
    const sidebar = new Sidebar();
    const owner = createPatch("command-center.sidebar");
    const feedback = new Map<HTMLButtonElement, Patches>();
    let disposed = false;
    let observer: MutationObserver | undefined;
    let observerFrame: ReturnType<typeof setTimeout> | undefined;

    function restoreFeedback(): boolean
    {
        try
        {
            return restorePatches(feedback.values());
        }
        finally
        {
            feedback.clear();
        }
    }

    function renderLayout(): void
    {
        if (!globalThis.document?.body || disposed)
            return;

        observer?.disconnect();
        try
        {
            prepareShell(context.content.css ?? uiCss);
            renderSections();
            renderSpaces();
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

    /** The Spaces label row keeps its React props even while its search field replaces the label. */
    function isSpacesRow(row: HTMLElement): boolean
    {
        if (row.querySelector('[data-slot="sidebar-group-label"]')?.textContent?.trim() === "Spaces")
            return true;

        const key = Object.keys(row).find((name) => name.startsWith("__reactFiber$"));
        let fiber = key ? (row as any)[key] : null;
        for (let index = 0; fiber && index < 32; index++, fiber = fiber.return)
            if (fiber.memoizedProps?.label === "Spaces" && fiber.memoizedProps?.onPlusClick)
                return true;

        return false;
    }

    /** Hides the native Spaces region in Autonom mode unless `devin_cloud` imports it. */
    function renderSpaces(): void
    {
        const hide = context.enabled && !context.content.devinCloud?.includes(spacesSection);
        const region = new Set<HTMLElement>();
        for (const row of document.querySelectorAll<HTMLElement>('div[data-slot="sidebar-label-row"]'))
        {
            if (!isSpacesRow(row) || row.closest("[data-autonom-section]"))
                continue;

            let group = row.closest<HTMLElement>('[data-slot="sidebar-group"]');
            while (group && !region.has(group))
            {
                region.add(group);
                const next = group.nextElementSibling;
                group = next instanceof HTMLElement && next.dataset.slot === "sidebar-group"
                    && !next.querySelector('[data-slot="sidebar-label-row"]') ? next : null;
            }
        }

        sidebar.hideSpaces(region, hide);
    }

    function renderSections(): void
    {
        const { content, items, enabled } = context;
        const menus = new Set(document.querySelectorAll<HTMLUListElement>('ul[aria-label="Pages"]'));
        sidebar.prune(new Set(enabled ? items.keys() : []));

        if (!enabled)
        {
            restoreFeedback();
            sections.prune(new Set());
            return;
        }

        for (const menu of menus)
        {
            const rows = new Map<string, HTMLElement>();
            for (const row of Array.from(menu.children) as HTMLElement[])
            {
                const button = row.querySelector<HTMLElement>('[data-slot="sidebar-menu-button"] > button[aria-label]');
                const id = button && nativeItemId(button);
                if (!id || !button)
                    continue;

                rows.set(id, row);
                sidebar.button(button, row, id, items.get(id)?.icon);
            }

            sections.sync(menu, content.sections, rows);
        }

        sections.prune(menus);
    }

    function onClick(event: MouseEvent): void
    {
        const { items, enabled } = context;
        if (disposed || !enabled || event.button !== 0)
            return;

        const button = (event.target as Element | null)?.closest<HTMLButtonElement>("button[data-autonom-item]");
        const id = button?.dataset.autonomItem;
        if (!button || !id || !items.get(id)?.actions?.left_click)
            return;

        event.preventDefault();
        event.stopImmediatePropagation();
        if (feedback.has(button))
            return;

        const patch = new Patches("command-center.click");
        feedback.set(button, patch);
        patch.attribute(button, "aria-busy", "true");
        void Promise.resolve().then(() =>
        {
            if (!disposed && feedback.get(button) === patch)
                return context.activate(id);
        }).catch((error) =>
        {
            if (disposed || feedback.get(button) !== patch)
                return;

            patch.attribute(button, "title", error instanceof Error ? error.message : String(error));
            console.error("[autonom]", error);
        }).finally(() =>
        {
            patch.restore();
            if (feedback.get(button) === patch)
                feedback.delete(button);
        });
    }

    owner.cleanup(() => sidebar.restore());
    owner.cleanup(() => sections.prune(new Set()));
    owner.cleanup(() => globalThis.document?.removeEventListener("click", onClick, true));
    owner.cleanup(() =>
    {
        observer?.disconnect();
        clearTimeout(observerFrame);
    });
    owner.cleanup(restoreFeedback);
    globalThis.document?.addEventListener("click", onClick, true);
    return {
        render: renderLayout,
        dispose(): void
        {
            disposed = true;
            owner.restore();
        },
    };
}
