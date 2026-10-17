import autonomFillMarkup from "../../../assets/icons/autonom-fill.svg";
import { object } from "../parse";
import { readPrivateFile, writePrivateFile } from "../storage";

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const acpAgentId = "devin-autonom";

const acpAgent = {
    name: "Autonom",
    version: "0.1.0",
    description: "Devin Local with daemon-owned Autonom sessions and scheduled wakes.",
    license: "AGPL-3.0-only",
    icon: `data:image/svg+xml;base64,${Buffer.from(autonomFillMarkup).toString("base64")}`,
};

const enabledAgentKeys = ["devin.acp.enabledAgents", "windsurf.acp.enabledAgents"];

export function acpRegistryPath(): string
{
    return join(homedir(), ".windsurf", "acp", "registry.json");
}

export function acpSettingsPath(): string
{
    return join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), "Devin", "User", "settings.json");
}

function parseJsonDocument(source: string): unknown
{
    let cleaned = "";
    let quoted = false;
    let escaped = false;
    for (let index = 0; index < source.length; index++)
    {
        const character = source[index]!;
        if (quoted)
        {
            cleaned += character;
            if (escaped)
                escaped = false;
            else if (character === "\\")
                escaped = true;
            else if (character === '"')
                quoted = false;
            continue;
        }
        if (character === '"')
        {
            quoted = true;
            cleaned += character;
            continue;
        }
        if (character === "/" && source[index + 1] === "/")
        {
            while (index < source.length && source[index] !== "\n")
                index++;
            index--;
            continue;
        }
        if (character === "/" && source[index + 1] === "*")
        {
            const end = source.indexOf("*/", index + 2);
            index = end < 0 ? source.length : end + 1;
            continue;
        }
        cleaned += character;
    }

    let ret = "";
    for (let index = 0; index < cleaned.length; index++)
    {
        const character = cleaned[index]!;
        ret += character;
        if (quoted)
        {
            if (escaped)
                escaped = false;
            else if (character === "\\")
                escaped = true;
            else if (character === '"')
                quoted = false;
            continue;
        }
        if (character === '"')
        {
            quoted = true;
            continue;
        }
        if (character === ",")
        {
            let next = index + 1;
            while (next < cleaned.length && " \t\r\n".includes(cleaned[next]!))
                next++;
            if (cleaned[next] === "]" || cleaned[next] === "}")
                ret = ret.slice(0, -1);
        }
    }

    return JSON.parse(ret);
}

async function readJsonFile(path: string): Promise<Record<string, unknown>>
{
    try
    {
        const record = object(parseJsonDocument(await readPrivateFile(path, 1048576)));
        if (!record)
            throw new Error("Expected a JSON object.");
        return record;
    }
    catch (error)
    {
        if ((error as NodeJS.ErrnoException).code === "ENOENT")
            return {};
        throw error;
    }
}

export async function acpRegistryIcons(registryPath = acpRegistryPath()): Promise<Record<string, string>>
{
    const registry = await readJsonFile(registryPath);
    const icons: Record<string, string> = {};
    for (const agent of Array.isArray(registry.agents) ? registry.agents : [])
    {
        const entry = object(agent);
        if (typeof entry?.id === "string" && typeof entry.icon === "string" && entry.icon.trim())
            icons[entry.id] = entry.icon;
    }
    return icons;
}

export async function ensureAcpAgent(options: {
    command: string;
    args?: string[];
    env?: Record<string, string>;
    registryPath?: string;
    settingsPath?: string;
}): Promise<void>
{
    if (!existsSync(options.command))
        throw new Error(`ACP agent binary is missing: ${options.command}`);

    const platformName = process.platform === "darwin" ? "darwin"
        : process.platform === "win32" ? "windows" : "linux";
    const platform = `${platformName}-${process.arch === "arm64" ? "aarch64" : "x86_64"}`;
    const binary: Record<string, unknown> = { archive: "", cmd: options.command, args: options.args ?? [] };
    if (options.env && Object.keys(options.env).length)
        binary.env = options.env;

    const entry = {
        id: acpAgentId,
        ...acpAgent,
        distribution: { binary: { [platform]: binary } },
    };

    const registryPath = options.registryPath ?? acpRegistryPath();
    const registry = await readJsonFile(registryPath);
    const agents = (Array.isArray(registry.agents) ? registry.agents : [])
        .filter((agent) => object(agent)?.id !== acpAgentId);
    const next = [...agents, entry];
    if (JSON.stringify(registry.agents) !== JSON.stringify(next))
    {
        registry.version = typeof registry.version === "string" ? registry.version : "1.0.0";
        registry.agents = next;
        await writePrivateFile(registryPath, `${JSON.stringify(registry, null, 4)}\n`);
    }

    const settingsPath = options.settingsPath ?? acpSettingsPath();
    const settings = await readJsonFile(settingsPath);
    let dirty = false;
    for (const key of enabledAgentKeys)
    {
        const enabled = object(settings[key]) ?? {};
        if (enabled[acpAgentId] !== true)
        {
            enabled[acpAgentId] = true;
            dirty = true;
        }
        settings[key] = enabled;
    }
    if (dirty)
        await writePrivateFile(settingsPath, `${JSON.stringify(settings, null, 4)}\n`);
}
