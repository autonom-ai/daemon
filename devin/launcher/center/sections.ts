import type { SidebarButton, SidebarSection } from "./content";
import { sectionIcon } from "./icons";

type SectionHeader = {
    li: HTMLLIElement;
    row: HTMLElement;
    section: SidebarSection;
    signature: string;
    searching: boolean;
    empty: HTMLLIElement | undefined;
};

const labelRowClass = "group/sidebar-label-row flex h-8 shrink-0 items-center justify-between "
    + "gap-px pl-[--sidebar-content-button-x-padding] pr-0.5 top-0 has-[[data-slot=input-group]]:px-0 "
    + "static z-auto bg-transparent";
const groupLabelClass = "text-12 text-text-secondary flex items-center rounded-md font-medium flex-1";
const buttonClass = "inline-flex touch-manipulation select-none items-center justify-center "
    + "outline-none [-webkit-touch-callout:none] disabled:pointer-events-none "
    + "disabled:cursor-not-allowed disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 "
    + "shrink-0 focus-ring bg-transparent hover:bg-tint-secondary hover:text-text-primary "
    + "data-[pressed]:bg-tint-secondary data-[pressed]:text-text-primary rounded-[6px] size-6 "
    + "[&_svg]:size-[16px] text-text-secondary";
const inputGroupClass = "group/input-group flex items-center relative w-full min-w-0 rounded-[6px] "
    + "outline-none text-text-primary placeholder:text-text-secondary h-7 border-0 bg-transparent shadow-none";
const inputAddonClass = "text-text-secondary h-auto gap-2 text-12 flex cursor-text items-center "
    + "justify-center select-none [&>svg:not([class*='size-'])]:size-[16px]";
const inputControlClass = "flex w-full min-w-0 py-[5px] px-[10px] focus-visible:outline-0 "
    + "rounded-none border-0 shadow-none hover:bg-transparent text-text-primary text-13 font-regular "
    + "placeholder:text-text-secondary caret-text-accent-primary flex-1 bg-transparent pl-[8px] outline-none";
const emptyClass = "px-2.5 py-1.5 text-[12px] text-ide-editor-color opacity-70";

/**
 * Renders custom section headers inside a Pages menu using the native
 * sidebar-label-row/sidebar-group-label presentation with hover-ready icon
 * buttons, plus an inline search field filtering the section's rows.
 */
export function createSections(): {
    sync(menu: HTMLUListElement, sections: SidebarSection[], rows: Map<string, HTMLElement>): void;
    prune(menus: Set<HTMLUListElement>): void;
}
{
    const headers = new Map<HTMLUListElement, Map<string, SectionHeader>>();
    const queries = new Map<string, string>();

    function remove(header: SectionHeader): void
    {
        header.empty?.remove();
        header.li.remove();
    }

    function signatureOf(section: SidebarSection): string
    {
        return JSON.stringify({ label: section.label ?? null, buttons: section.buttons ?? [] });
    }

    function buttonElement(header: SectionHeader, button: SidebarButton): HTMLButtonElement
    {
        const label = button.label ?? (button.search ? "Search" : button.id);
        const element = document.createElement("button");
        element.type = "button";
        element.className = buttonClass;
        element.setAttribute("aria-label", label);
        element.title = label;
        element.appendChild(sectionIcon(button.icon, button.search ? "search" : "plus"));
        if (button.search)
        {
            element.addEventListener("click", () =>
            {
                header.searching = true;
                fillRow(header);
                header.row.querySelector<HTMLInputElement>("input")?.focus();
            });
        }
        else
        {
            element.dataset.autonomItem = button.id;
        }

        return element;
    }

    function filterAll(sectionId: string): void
    {
        for (const [menu] of headers)
            filter(menu, sectionId);
    }

    function closeSearch(header: SectionHeader): void
    {
        header.searching = false;
        queries.delete(header.section.id);
        fillRow(header);
        filterAll(header.section.id);
    }

    function searchGroup(header: SectionHeader): HTMLElement
    {
        const group = document.createElement("div");
        group.dataset.slot = "input-group";
        group.setAttribute("role", "group");
        group.className = inputGroupClass;
        const start = document.createElement("div");
        start.dataset.slot = "input-group-addon";
        start.dataset.align = "inline-start";
        start.className = `${inputAddonClass} order-first pl-[--sidebar-content-button-x-padding]`;
        start.appendChild(sectionIcon("search"));
        const input = document.createElement("input");
        input.dataset.slot = "input-group-control";
        input.type = "text";
        input.className = inputControlClass;
        input.placeholder = `Search ${header.section.label!.toLowerCase()}`;
        input.value = queries.get(header.section.id) ?? "";
        input.addEventListener("input", () =>
        {
            if (input.value)
                queries.set(header.section.id, input.value);
            else
                queries.delete(header.section.id);

            filterAll(header.section.id);
        });
        input.addEventListener("keydown", (event) =>
        {
            if (event.key !== "Escape")
                return;

            event.stopPropagation();
            closeSearch(header);
        });
        const end = document.createElement("div");
        end.dataset.slot = "input-group-addon";
        end.dataset.align = "inline-end";
        end.className = `${inputAddonClass} order-last !-ml-px !mr-0 !pr-1`;
        const clear = document.createElement("button");
        clear.type = "button";
        clear.className = buttonClass;
        clear.setAttribute("aria-label", "Clear search");
        clear.title = "Clear search";
        clear.appendChild(sectionIcon("close"));
        clear.addEventListener("click", () => closeSearch(header));
        end.appendChild(clear);
        group.append(start, input, end);
        return group;
    }

    function fillRow(header: SectionHeader): void
    {
        const section = header.section;
        header.row.replaceChildren();
        if (header.searching)
        {
            header.row.appendChild(searchGroup(header));
            return;
        }

        const label = document.createElement("div");
        label.dataset.slot = "sidebar-group-label";
        label.className = groupLabelClass;
        label.textContent = section.label ?? "";
        header.row.appendChild(label);
        for (const button of section.buttons ?? [])
            if (!button.hidden)
                header.row.appendChild(buttonElement(header, button));
    }

    function build(section: SidebarSection): SectionHeader
    {
        const li = document.createElement("li");
        li.dataset.autonomSection = section.id;
        li.setAttribute("role", "presentation");
        const row = document.createElement("div");
        row.dataset.slot = "sidebar-label-row";
        row.className = labelRowClass;
        li.appendChild(row);
        const header: SectionHeader = { li, row, section, signature: signatureOf(section), searching: false, empty: undefined };
        fillRow(header);
        return header;
    }

    function filter(menu: HTMLUListElement, sectionId: string): void
    {
        const header = headers.get(menu)?.get(sectionId);
        if (!header)
            return;

        const section = header.section;
        const query = queries.get(section.id)?.toLowerCase();
        let visible = 0;
        for (const item of section.items)
        {
            if (item.hidden)
                continue;

            const button = menu.querySelector<HTMLElement>(`button[data-autonom-item="${CSS.escape(item.id)}"]`);
            const row = button?.closest<HTMLElement>("li");
            if (!button || !row)
                continue;

            const label = button.getAttribute("aria-label") ?? row.textContent ?? "";
            const show = !query || label.toLowerCase().includes(query);
            row.style.display = show ? "" : "none";
            visible += Number(show);
        }

        if (query && visible === 0)
        {
            header.empty ??= emptyRow(section);
            if (header.empty.parentElement !== header.li)
                header.li.appendChild(header.empty);
        }
        else
        {
            header.empty?.remove();
        }
    }

    function emptyRow(section: SidebarSection): HTMLLIElement
    {
        const li = document.createElement("li");
        li.dataset.autonomSectionEmpty = section.id;
        li.setAttribute("role", "presentation");
        li.className = emptyClass;
        li.textContent = `No ${section.label!.toLowerCase()} found`;
        return li;
    }

    return {
        sync(menu, sections, rows): void
        {
            let sectionHeaders = headers.get(menu);
            if (!sectionHeaders)
            {
                sectionHeaders = new Map();
                headers.set(menu, sectionHeaders);
            }

            const displayed = new Set<string>();
            let anchor: HTMLElement | null = null;
            for (let index = sections.length - 1; index >= 0; index--)
            {
                const section = sections[index]!;
                anchor = section.items.map((item) => rows.get(item.id)).find(Boolean) ?? anchor;
                if (!section.label || section.items.length > 0 && section.items.every((item) => item.hidden))
                    continue;

                displayed.add(section.id);
                let header = sectionHeaders.get(section.id);
                if (!header)
                {
                    header = build(section);
                    sectionHeaders.set(section.id, header);
                }
                else
                {
                    header.section = section;
                    if (header.signature !== signatureOf(section))
                    {
                        header.signature = signatureOf(section);
                        fillRow(header);
                    }
                }

                if (header.li.parentElement !== menu || header.li.nextElementSibling !== anchor)
                    menu.insertBefore(header.li, anchor);

                anchor = header.li;
            }

            for (const [id, header] of sectionHeaders)
            {
                if (displayed.has(id))
                    continue;

                remove(header);
                sectionHeaders.delete(id);
                queries.delete(id);
            }

            for (const section of sections)
                filter(menu, section.id);
        },
        prune(menus): void
        {
            for (const [menu, sectionHeaders] of headers)
            {
                if (menus.has(menu))
                    continue;

                for (const [id, header] of sectionHeaders)
                {
                    remove(header);
                    sectionHeaders.delete(id);
                    queries.delete(id);
                }

                headers.delete(menu);
            }
        },
    };
}
