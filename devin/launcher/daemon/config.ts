import { expandPath } from "../config";
import { object } from "../parse";
import { readPrivateFile, writePrivateFile } from "../storage";

import { parseDocument, parse as parseYaml } from "yaml";

import { dirname, resolve } from "node:path";

export async function readDataDir(configFile: string): Promise<string>
{
    const config = await readDaemonConfig(configFile);
    const value = config.dataDir;
    if (typeof value !== "string" || !value.trim())
        return dirname(resolve(configFile));
    return value === "~" || value.startsWith("~/") ? expandPath(value) : resolve(dirname(configFile), value);
}

export async function readDaemonConfig(configFile: string): Promise<Record<string, unknown>>
{
    let content: string;
    try
    {
        content = await readPrivateFile(configFile);
    }
    catch (error)
    {
        if ((error as NodeJS.ErrnoException).code === "ENOENT")
            return {};
        throw error;
    }
    const document = parseDocument(content);
    if (document.errors.length)
        throw new Error("Daemon configuration contains invalid YAML.");
    const daemonValue = object(document.toJS()) ?? {};
    const ret: Record<string, unknown> = {};
    for (const name of daemonFields)
    {
        if (name in daemonValue)
            ret[name] = daemonValue[name];
    }
    return ret;
}

export async function saveDaemon(configFile: string, values: unknown): Promise<void>
{
    const patch = object(values);
    if (patch === undefined)
        throw new Error("Daemon settings must be a mapping.");
    await ensureDefaultConfig(configFile);
    const document = parseDocument(await readPrivateFile(configFile));
    if (document.errors.length)
        throw new Error("Daemon configuration contains invalid YAML.");
    for (const [field, value] of Object.entries(patch))
    {
        if (!daemonFields.includes(field))
            throw new Error("Unsupported daemon setting.");
        if (field === "compactOnResume")
        {
            if (typeof value !== "boolean")
                throw new Error("compactOnResume must be a boolean.");
        }
        else if (typeof value !== "string" || !value.trim() || value.includes("\0"))
            throw new Error("Daemon settings require non-empty string values.");
        if (["offlineStartAfter", "offlineCompactAfter", "executionTimeout"].includes(field)
            && (typeof value !== "string" || !/^[1-9][0-9]{0,8}[smhd]?$/.test(value)))
            throw new Error("Durations must be positive values such as 30m, 1h, or integer seconds.");
        document.set(field, value);
    }
    await writePrivateFile(configFile, document.toString());
}

export async function ensureDefaultConfig(configFile: string): Promise<void>
{
    try
    {
        await readPrivateFile(configFile);
    }
    catch (error)
    {
        if ((error as NodeJS.ErrnoException).code === "ENOENT")
            await writePrivateFile(configFile, defaultConfigTemplate);
        else
            throw error;
    }
}

export async function readRouterKey(configFile: string): Promise<string>
{
    try
    {
        const document = parseYaml(await readPrivateFile(configFile)) as unknown;
        const router = object(object(document)?.router);
        const key = router?.key;
        return typeof key === "string" ? key : "";
    }
    catch
    {
        return "";
    }
}

export const defaultConfigTemplate = `dataDir: ~/.local/share/autonom
devinCommand: devin
executionTimeout: 30m
compactOnResume: false
offlineStartAfter: 1h
offlineCompactAfter: 1h
router:
  type: openrouter
  key: ""
  url: https://openrouter.ai
  name: OpenRouter
  referer: ""
  title: ""
`;

const daemonFields = [
    "dataDir",
    "devinCommand",
    "compactOnResume",
    "offlineStartAfter",
    "offlineCompactAfter",
    "executionTimeout",
];
