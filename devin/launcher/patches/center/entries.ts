import type { DirectoryEntry } from "../../center/directory";
import { sectionIcon } from "./icons";

/** Listing rows have no action until room/profile navigation is implemented. */
export function createEntries()
{
    const lists = new WeakMap<HTMLElement, Map<string, HTMLLIElement>>();

    return {
        sync(header: HTMLElement, section: string, entries: readonly DirectoryEntry[]): void
        {
            let rows = lists.get(header);
            if (!rows)
            {
                rows = new Map();
                lists.set(header, rows);
            }

            const wanted = new Set(entries.map((entry) => entry.name));
            for (const [name, row] of rows)
            {
                if (!wanted.has(name))
                {
                    row.remove();
                    rows.delete(name);
                }
            }

            let list = header.querySelector<HTMLUListElement>("ul[data-autonom-directory]");
            if (!entries.length)
            {
                list?.remove();
                return;
            }

            if (!list)
            {
                list = document.createElement("ul");
                list.dataset.autonomDirectory = section;
                list.setAttribute("aria-label", section === "rooms" ? "Rooms" : "Profiles");
                list.className = "flex w-full min-w-0 flex-col gap-0.5";
                header.appendChild(list);
            }

            let previous: HTMLLIElement | undefined;
            for (const entry of entries)
            {
                let row = rows.get(entry.name);
                if (!row)
                {
                    row = document.createElement("li");
                    row.dataset.autonomEntry = entry.name;
                    row.className = "flex min-w-0 items-center gap-2 px-2.5 py-1.5 text-13 text-text-secondary";
                    const icon = sectionIcon(entry.icon);
                    icon.setAttribute("width", "18");
                    icon.setAttribute("height", "18");
                    icon.classList.add("shrink-0");
                    const label = document.createElement("span");
                    label.className = "truncate";
                    label.textContent = entry.name;
                    row.append(icon, label);
                    rows.set(entry.name, row);
                }

                const next = previous ? previous.nextElementSibling : list.firstElementChild;
                if (next !== row)
                    list.insertBefore(row, next);

                previous = row;
            }
        },
        filter(header: HTMLElement, query: string | undefined): number
        {
            let visible = 0;
            for (const [name, row] of lists.get(header) ?? [])
            {
                const show = !query || name.toLowerCase().includes(query);
                row.style.display = show ? "" : "none";
                visible += Number(show);
            }

            return visible;
        },
    };
}
