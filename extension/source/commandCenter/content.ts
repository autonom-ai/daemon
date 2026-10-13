/**
 * Shared, environment-free content model for the Command Center.
 *
 * This module is imported by both the extension host (Node) and the injected
 * renderer runtime (browser), so it must stay free of Node and DOM globals.
 * `overlayItems` is the single source of truth for how a user configuration
 * maps onto Devin's native navigation manifest.
 */

/** One user-declared sidebar entry: rename, remove, or add a native page row. */
export interface SidebarItem {
    /** Must match a native manifest id to edit it; a new id creates a row. */
    id: string;
    /** Replacement label; omitted keeps the native label. */
    label?: string;
    /** Replacement icon; omitted keeps the native icon. */
    icon?: string;
    /** Removes the row for Autonom mode while leaving the native manifest intact. */
    hidden?: boolean;
    /** Custom tab id; when present the row navigates to `/autonom/<tab>`. */
    tab?: string;
}

/**
 * A native navigation manifest item. The adapter preserves every field it does
 * not explicitly replace, so unknown Desktop fields survive untouched.
 */
export interface NativeItem {
    id: string;
    label: string;
    icon: string;
    path: string;
    [key: string]: unknown;
}

/** A validated custom page: its display title and trusted HTML fragment. */
export interface CenterPage {
    title: string;
    html: string;
    autonom?: boolean;
}

/** Fully validated configuration plus the revision hash used for reload checks. */
export interface CenterContent {
    enabled: boolean;
    items: SidebarItem[];
    tabs: Record<string, CenterPage>;
    activeTab?: string;
    revision?: string;
}

/**
 * Merges user items onto a native manifest.
 *
 * Pure and non-mutating: returns a new array with new item objects, so React's
 * external-store identity checks and the native manifest stay intact. Throws
 * when a new row has no tab, which keeps a bad config from producing a dead
 * sidebar entry. Callers validate before reaching this function in production;
 * the throw is the last line of defense.
 */
export function overlayItems(native: NativeItem[], content: CenterContent): NativeItem[] {
    if (!content.enabled)
        return native;
    const ret = native.map((item) => ({ ...item }));
    for (const item of content.items) {
        const index = ret.findIndex((entry) => entry.id === item.id);
        if (item.hidden) {
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

function escapeHtml(value: string): string {
    return value.replace(/[&<>"']/g, (character) => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
    })[character]!);
}

/**
 * Wraps a trusted page fragment in a locked-down document.
 *
 * The rendered page is intentionally inert: no scripts, no network, no forms,
 * no frames, and data-only images. Only the title and body fragment are
 * inserted, and the title is HTML-escaped so it cannot break out of `<title>`.
 */
export function pageHtml(page: CenterPage): string {
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

/**
 * Wraps the trusted Autonom Command Center UI bundle.
 *
 * This mode enables scripts so the native Webview messaging bridge (`acquireVsCodeApi()`)
 * can communicate with the extension host. It maintains a restrictive CSP:
 * no network (`connect-src 'none'`), no frames, and styles/scripts inline only.
 */
export function autonomPageHtml(page: CenterPage, scriptBundle = "", styleCss = ""): string {
    const title = escapeHtml(page.title);
    return `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none';
style-src 'unsafe-inline'; img-src data:; font-src data:; frame-src 'none'; form-action 'none'; base-uri 'none';">
<title>${title}</title>
<style>
${styleCss}
</style>
</head>
<body>
<div id="app">${page.html || ""}</div>
<script>
${scriptBundle}
</script>
</body></html>`;
}
