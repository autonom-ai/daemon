import { Patches, restorePatches } from "../lifecycle";
import { createIcon } from "./icons";

/** Borrows native sidebar rows without losing their original icon nodes. */
export class Sidebar
{
    private readonly buttons = new Map<HTMLElement, { patch: Patches; icon: string | undefined }>();
    private readonly spaces = new Map<HTMLElement, Patches>();

    button(button: HTMLElement, row: HTMLElement, id: string, icon: string | undefined): void
    {
        let entry = this.buttons.get(button);
        if (entry && (entry.icon !== icon || button.getAttribute("data-autonom-item") !== id))
        {
            entry.patch.restore();
            this.buttons.delete(button);
            entry = undefined;
        }
        if (entry)
            return;

        const patch = new Patches("command-center.sidebar-row");
        patch.attribute(button, "data-autonom-item", id);
        this.buttons.set(button, { patch, icon });
        const svg = icon && createIcon(icon);
        if (!svg)
            return;

        svg.setAttribute("width", "18");
        svg.setAttribute("height", "18");
        svg.dataset.autonomIcon = icon;
        const slot = button.parentElement?.querySelector<HTMLElement>('[data-slot="sidebar-menu-button-icon"]')
            ?? row.querySelector<HTMLElement>('[data-slot="sidebar-menu-button-icon"]');
        if (slot)
        {
            const original = [...slot.childNodes];
            patch.attribute(slot, "data-autonom-icon", icon!);
            patch.cleanup(() =>
            {
                if (slot.childNodes.length === 1 && slot.firstChild === svg
                    && original.every((node) => !node.parentNode))
                    slot.replaceChildren(...original);
                else
                {
                    svg.remove();
                    return false;
                }
            });
            slot.replaceChildren(svg);
            return;
        }

        const native = button.parentElement?.querySelector<SVGElement>("svg") ?? row.querySelector<SVGElement>("svg");
        if (native)
        {
            const parent = native.parentNode;
            patch.cleanup(() =>
            {
                if (svg.parentNode === parent && !native.parentNode)
                    svg.replaceWith(native);
                else
                {
                    svg.remove();
                    return false;
                }
            });
            native.replaceWith(svg);
        }
    }

    hideSpaces(groups: Set<HTMLElement>, hide: boolean): void
    {
        for (const [group, patch] of this.spaces)
        {
            if (hide && groups.has(group))
                continue;
            patch.restore();
            this.spaces.delete(group);
        }
        if (!hide)
            return;
        for (const group of groups)
        {
            if (this.spaces.has(group))
                continue;
            const patch = new Patches("command-center.spaces");
            patch.style(group, "display", "none");
            this.spaces.set(group, patch);
        }
    }

    prune(ids: Set<string>): void
    {
        for (const [button, entry] of this.buttons)
        {
            if (button.isConnected && ids.has(button.dataset.autonomItem!))
                continue;
            entry.patch.restore();
            this.buttons.delete(button);
        }
    }

    restore(): boolean
    {
        try
        {
            return restorePatches([...this.buttons.values()].map((entry) => entry.patch)
                .concat([...this.spaces.values()]));
        }
        finally
        {
            this.buttons.clear();
            this.spaces.clear();
        }
    }
}
