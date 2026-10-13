export type SidebarItem = {
    id: string;
    label?: string;
    icon?: string;
    hidden?: boolean;
    tab?: string;
};

export type NativeItem = {
    id: string;
    label: string;
    icon: string;
    path: string;
    [key: string]: unknown;
};

export type CenterPage = {
    title: string;
    html: string;
};

export type CenterContent = {
    enabled: boolean;
    items: SidebarItem[];
    tabs: Record<string, CenterPage>;
    activeTab?: string;
    revision?: string;
};

export function overlayItems(native: NativeItem[], content: CenterContent): NativeItem[]
{
    if (!content.enabled)
        return native;
    const ret = native.map((item) => ({ ...item }));
    for (const item of content.items)
    {
        const index = ret.findIndex((entry) => entry.id === item.id);
        if (item.hidden)
        {
            if (index >= 0)
                ret.splice(index, 1);
            continue;
        }
        if (index < 0 && !item.tab)
            throw new Error(`New sidebar item needs a tab: ${item.id}`);
        const replacement: NativeItem = {
            ...(index < 0 ? {} : ret[index]),
            id: item.id,
            label: item.label ?? ret[index]?.label ?? item.id,
            icon: item.icon ?? ret[index]?.icon ?? "file",
            path: item.tab ? `/autonom/${item.tab}` : ret[index]!.path,
        };
        if (index < 0)
            ret.push(replacement);
        else
            ret[index] = replacement;
    }
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

export function pageHtml(page: CenterPage): string
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
