import { object } from "../parse";
import { assetVersion, readDescriptor, readPrivateFile } from "../storage";
import type { ActionSource, CenterContent, ItemAction, SidebarItem, SidebarSection } from "./content";
import { visibleItems } from "./content";

import { parseDocument } from "yaml";

import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import { dirname, extname, isAbsolute, relative, resolve, sep } from "node:path";

function identifier(value: unknown): value is string
{
    return typeof value === "string" && /^[a-z][a-z0-9-]{0,63}$/.test(value);
}

async function assetPath(directory: string, file: string): Promise<string>
{
    if (!file.trim() || isAbsolute(file) || file.includes("\0"))
        throw new Error("UI files must be relative paths inside the configuration directory.");

    const path = resolve(directory, file);
    const child = relative(directory, path);
    if (!child || child === ".." || child.startsWith(`..${sep}`) || isAbsolute(child))
        throw new Error("UI files must stay inside the configuration directory.");

    const real = await realpath(path);
    const contained = relative(directory, real);
    if (!contained || contained === ".." || contained.startsWith(`..${sep}`) || isAbsolute(contained))
        throw new Error("UI files must stay inside the configuration directory.");

    if ((await lstat(path)).isSymbolicLink())
        throw new Error("UI files must not be symbolic links.");

    return real;
}

function allowFields(record: Record<string, unknown>, fields: string[]): void
{
    for (const field of Object.keys(record))
        if (!fields.includes(field))
            throw new Error(`Unsupported UI field: ${field}`);
}

export async function loadCenter(configPath: string): Promise<CenterContent>
{
    const document = parseDocument(await readPrivateFile(configPath));
    if (document.errors.length)
        throw new Error("UI definition contains invalid YAML.");

    const config = object(document.toJS({ maxAliasCount: 100 }));
    const sections = config?.sections ?? [];
    const topItems = config?.items ?? [];
    if (!config || config.enabled !== undefined && typeof config.enabled !== "boolean"
        || !Array.isArray(sections) || sections.length > 32 || !Array.isArray(topItems))
        throw new Error("UI items and sections must be lists (at most 32 sections).");

    allowFields(config, ["enabled", "items", "sections", "active_item", "devin_cloud"]);
    const cloudImports = config.devin_cloud ?? [];
    if (!Array.isArray(cloudImports) || cloudImports.length > 100 || !cloudImports.every(identifier)
        || new Set(cloudImports).size !== cloudImports.length)
        throw new Error("devin_cloud must list unique native element ids.");

    const imported: string[] = cloudImports;
    const ret: CenterContent = { enabled: config.enabled !== false, sections: [], devinCloud: imported };
    const directory = await realpath(dirname(configPath));
    const ids = new Set<string>();
    const assets = new Map<string, Promise<{ action: ItemAction; size: number }>>();
    let count = 0;
    async function loadItems(values: unknown[]): Promise<SidebarItem[]>
    {
        const ret: SidebarItem[] = [];
        for (const value of values)
        {
            const item = object(value);
            if (!item || !identifier(item.id)
                || item.label !== undefined && (typeof item.label !== "string" || item.label.length > 200)
                || item.icon !== undefined && (typeof item.icon !== "string"
                    || !/^(?:[a-z][a-z0-9-]{0,63}|Icon[A-Za-z0-9]+)$/.test(item.icon))
                || item.hidden !== undefined && typeof item.hidden !== "boolean" || item.tab !== undefined)
                throw new Error("Invalid UI item.");

            allowFields(item, ["id", "label", "icon", "hidden", "actions"]);
            if (imported.includes(item.id) && item.actions !== undefined)
                throw new Error(`Imported Devin Cloud element cannot have a custom action: ${item.id}`);

            if (ids.has(item.id))
                throw new Error(`Duplicate UI id: ${item.id}`);

            ids.add(item.id);
            if (++count > 100)
                throw new Error("UI definition exceeds 100 items.");

            const entry: SidebarItem = { id: item.id };
            if (typeof item.label === "string")
                entry.label = item.label;
            if (typeof item.icon === "string")
                entry.icon = item.icon;
            if (typeof item.hidden === "boolean")
                entry.hidden = item.hidden;

            if (item.actions !== undefined)
            {
                const actions = object(item.actions);
                if (!actions || Object.keys(actions).length !== 1 || typeof actions.left_click !== "string")
                    throw new Error("UI items support only actions.left_click with an HTML or JS file path.");

                const file = actions.left_click;
                const extension = extname(file).toLowerCase();
                if (extension !== ".html" && extension !== ".js")
                    throw new Error("left_click actions must reference .html or .js files.");

                const path = await assetPath(directory, file);
                const normalized = relative(directory, path);
                let asset = assets.get(normalized);
                if (!asset)
                {
                    asset = (async () =>
                    {
                        const descriptor = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
                        try
                        {
                            const attributes = await descriptor.stat();
                            if (!attributes.isFile() || attributes.size > 262144)
                                throw new Error("UI action must be a bounded regular file (at most 256 KiB).");

                            return {
                                action: {
                                    file: normalized,
                                    type: extension === ".html" ? "html" : "js",
                                    version: assetVersion(attributes),
                                },
                                size: attributes.size,
                            };
                        }
                        finally
                        {
                            await descriptor.close();
                        }
                    })();
                    assets.set(normalized, asset);
                }

                entry.actions = { left_click: (await asset).action };
            }

            if (!entry.hidden && !entry.actions && !imported.includes(entry.id))
                throw new Error(`Visible UI item needs a left_click action: ${entry.id}`);

            ret.push(entry);
        }

        return ret;
    }

    ret.items = await loadItems(topItems);
    for (const value of sections)
    {
        const section = object(value);
        const entries = section?.items ?? [];
        if (!section || !identifier(section.id) || !Array.isArray(entries)
            || section.label !== undefined && (typeof section.label !== "string" || section.label.length > 200))
            throw new Error("Invalid UI section.");

        allowFields(section, ["id", "label", "items"]);
        if (ids.has(section.id))
            throw new Error(`Duplicate UI id: ${section.id}`);

        ids.add(section.id);
        const loaded: SidebarSection = { id: section.id, items: await loadItems(entries) };
        if (typeof section.label === "string")
            loaded.label = section.label;

        ret.sections.push(loaded);
    }

    if ((await Promise.all(assets.values())).reduce((total, asset) => total + asset.size, 0) > 1048576)
        throw new Error("UI action content exceeds 1 MiB.");

    try
    {
        ret.css = await readPrivateFile(await assetPath(directory, "ui.css"));
    }
    catch (error)
    {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT")
            throw error;
    }

    if (config.active_item !== undefined)
    {
        if (!identifier(config.active_item) || !visibleItems(ret).some((item) => item.id === config.active_item
            && item.actions?.left_click.type === "html"))
            throw new Error("active_item must identify a visible HTML action.");

        ret.activeItem = config.active_item;
    }

    ret.revision = createHash("sha256").update(JSON.stringify(ret)).digest("hex");
    return ret;
}

export type ActionCache = Map<string, { version: string; source: Promise<ActionSource> }>;

export async function loadAction(
    configPath: string,
    content: CenterContent,
    id: string,
    revision: string,
    cache: ActionCache,
): Promise<ActionSource>
{
    if (revision !== content.revision)
        throw new Error("The UI definition changed. Retry the action after reload.");

    const action = visibleItems(content).find((item) => item.id === id)?.actions?.left_click;
    if (!action)
        throw new Error(`Unknown or hidden UI action: ${id}`);

    const key = resolve(dirname(configPath), action.file);
    const cached = cache.get(key);
    if (cached?.version === action.version)
        return cached.source;

    const source = (async (): Promise<ActionSource> =>
    {
        const directory = await realpath(dirname(configPath));
        const descriptor = await open(await assetPath(directory, action.file), constants.O_RDONLY | constants.O_NOFOLLOW);
        try
        {
            const attributes = await descriptor.stat();
            if (!attributes.isFile() || attributes.size > 262144 || assetVersion(attributes) !== action.version)
                throw new Error("The UI action file changed. Retry after reload.");

            const source = await readDescriptor(descriptor, 262144);
            if (assetVersion(await descriptor.stat()) !== action.version)
                throw new Error("The UI action file changed while being read.");

            return { type: action.type, source };
        }
        finally
        {
            await descriptor.close();
        }
    })();
    cache.set(key, { version: action.version, source });
    try
    {
        return await source;
    }
    catch (error)
    {
        if (cache.get(key)?.source === source)
            cache.delete(key);

        throw error;
    }
}
