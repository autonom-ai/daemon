import type { CenterContent, SidebarItem } from "./content";
import { readPrivateFile, revision } from "./files";

import { realpath } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";

function object(value: unknown): value is Record<string, unknown>
{
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

function identifier(value: unknown): value is string
{
    return typeof value === "string" && /^[a-z][a-z0-9-]{0,63}$/.test(value);
}

async function pageFile(directory: string, file: unknown): Promise<string>
{
    if (typeof file !== "string" || isAbsolute(file))
        throw new Error("Tab files must be relative paths inside the configuration directory.");
    const path = resolve(directory, file);
    const child = relative(directory, path);
    if (child === ".." || child.startsWith(`..${sep}`) || isAbsolute(child))
        throw new Error("Tab files must stay inside the configuration directory.");
    const real = await realpath(path).catch(() => undefined);
    const contained = real === undefined ? "" : relative(directory, real);
    if (contained === "" || contained === ".." || contained.startsWith(`..${sep}`) || isAbsolute(contained))
        throw new Error("Tab files must stay inside the configuration directory.");
    return readPrivateFile(path, 262144);
}

export async function loadCenter(configPath: string): Promise<CenterContent>
{
    const config: unknown = JSON.parse(await readPrivateFile(configPath));
    if (!object(config) || typeof config.enabled !== "boolean" || !Array.isArray(config.items)
        || !object(config.tabs) || config.items.length > 100 || Object.keys(config.tabs).length > 100)
        throw new Error("Command Center needs enabled, items (at most 100), and tabs (at most 100).");
    const ret: CenterContent = { enabled: config.enabled, items: [], tabs: {} };
    const directory = await realpath(dirname(configPath));
    let total = 0;
    for (const [id, page] of Object.entries(config.tabs))
    {
        if (!identifier(id) || !object(page) || typeof page.title !== "string" || page.title.length > 200)
            throw new Error(`Invalid tab: ${id}`);
        const html = await pageFile(directory, page.file);
        total += Buffer.byteLength(html);
        if (total > 1048576)
            throw new Error("Command Center content exceeds 1 MiB.");
        ret.tabs[id] = { title: page.title, html };
    }
    const ids = new Set<string>();
    for (const item of config.items)
    {
        if (!object(item) || !identifier(item.id)
            || item.label !== undefined && (typeof item.label !== "string" || item.label.length > 200)
            || item.icon !== undefined && (typeof item.icon !== "string"
                || !/^(?:[a-z][a-z0-9-]{0,63}|Icon[A-Za-z0-9]+)$/.test(item.icon))
            || item.hidden !== undefined && typeof item.hidden !== "boolean"
            || item.tab !== undefined && !identifier(item.tab))
            throw new Error("Invalid sidebar item.");
        if (ids.has(item.id))
            throw new Error(`Duplicate sidebar item: ${item.id}`);
        ids.add(item.id);
        if (typeof item.tab === "string" && !Object.hasOwn(ret.tabs, item.tab))
            throw new Error(`Unknown tab: ${item.tab}`);
        ret.items.push(item as unknown as SidebarItem);
    }
    if (config.activeTab !== undefined)
    {
        if (!identifier(config.activeTab) || !Object.hasOwn(ret.tabs, config.activeTab))
            throw new Error(`Unknown active tab: ${String(config.activeTab)}`);
        if (!ret.items.some((item) => item.tab === config.activeTab && !item.hidden))
            throw new Error("The active tab must have a visible sidebar item.");
        ret.activeTab = config.activeTab;
    }
    ret.revision = revision(JSON.stringify(ret));
    return ret;
}
