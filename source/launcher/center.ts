export type ItemAction = {
    type: "html" | "js";
    file: string;
    version: string;
};

export type SidebarItem = {
    id: string;
    label?: string;
    icon?: string;
    hidden?: boolean;
    actions?: { left_click: ItemAction };
};

export type SidebarSection = {
    id: string;
    label?: string;
    items: SidebarItem[];
};

export type NativeItem = {
    id: string;
    label: string;
    icon: string;
    path: string;
    [key: string]: unknown;
};

export type CenterContent = {
    enabled: boolean;
    sections: SidebarSection[];
    devinCloud?: string[];
    css?: string;
    activeItem?: string;
    revision?: string;
};

export type ActionSource = {
    type: "html" | "js";
    source: string;
};

export function visibleItems(content: CenterContent): SidebarItem[]
{
    return content.sections.flatMap((section) => section.items).filter((item) => !item.hidden);
}

export function overlayItems(native: NativeItem[], content: CenterContent): NativeItem[]
{
    if (!content.enabled)
        return native;

    const originals = new Map(native.map((item) => [item.id, item]));
    const imported = new Set(content.devinCloud ?? []);
    for (const id of imported)
        if (!originals.has(id))
            throw new Error(`Unknown Devin Cloud element: ${id}`);
    const ret = visibleItems(content).map((item) =>
    {
        const original = originals.get(item.id);
        if (!item.actions?.left_click && (!original || !imported.has(item.id)))
            throw new Error(`New sidebar item needs a left_click action: ${item.id}`);

        return {
            ...original,
            id: item.id,
            label: item.label ?? original?.label ?? item.id,
            icon: item.icon ?? original?.icon ?? "file",
            path: item.actions?.left_click ? `/autonom/${item.id}` : original!.path,
        };
    });
    const placed = new Set(content.sections.flatMap((section) => section.items).map((item) => item.id));
    for (const id of imported)
        if (!placed.has(id))
            ret.push({ ...originals.get(id)! });

    return ret;
}

export function isFullDocument(html: string): boolean
{
    const head = html.trimStart().slice(0, 16).toLowerCase();
    return head.startsWith("<!doctype") || head.startsWith("<html");
}

function escapeHtml(value: string): string
{
    return value.replace(/[&<>"']/g, (character) => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
    })[character]!);
}

export function pageHtml(page: { title: string; html: string }): string
{
    const title = escapeHtml(page.title);
    return `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none';
style-src 'unsafe-inline'; img-src data:; font-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none';">
<title>${title}</title><style>
html,body{margin:0;min-height:100%;background:var(--vscode-editor-background);color:var(--vscode-foreground);}
body{padding:32px;box-sizing:border-box;font:var(--vscode-font-size) var(--vscode-font-family);}
h1{font-size:28px;font-weight:500;}p{line-height:1.6;}
</style></head><body>${page.html}</body></html>`;
}
