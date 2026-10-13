import { readPrivateFile, writePrivateFile } from "./files";
import { object } from "./parse";

import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { parse as parseYaml, parseDocument, stringify as stringifyYaml } from "yaml";

export type LauncherSettings = {
    port: number;
    configFile: string;
    commandCenterConfig: string;
};

export function defaultSettingsPath(): string
{
    return join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), "autonom", "launcher.yml");
}

export function defaultDaemonConfigPath(): string
{
    return join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), "autonom", "config.yml");
}

export function expandPath(path: string): string
{
    return path.startsWith("~/") ? join(homedir(), path.slice(2)) : resolve(path);
}

export async function readSettings(path: string): Promise<Partial<LauncherSettings>>
{
    const document = parseDocument(await readPrivateFile(path));
    if (document.errors.length)
        throw new Error("Launcher settings contain invalid YAML.");
    return validateSettings(document.toJS());
}

export async function saveSettings(path: string, settings: LauncherSettings): Promise<void>
{
    await writePrivateFile(path, stringifyYaml(settings));
}

export function validateSettings(value: unknown): Partial<LauncherSettings>
{
    const record = object(value);
    if (record === undefined)
        throw new Error("Launcher settings must be a mapping.");
    const ret: Partial<LauncherSettings> = {};
    if (record.port !== undefined)
    {
        if (typeof record.port !== "number" || !Number.isInteger(record.port)
            || record.port < 1 || record.port > 65535)
            throw new Error("The daemon port must be an integer between 1 and 65535.");
        ret.port = record.port;
    }
    for (const field of ["configFile", "commandCenterConfig"] as const)
    {
        const path = record[field];
        if (path === undefined)
            continue;
        if (typeof path !== "string" || !path.trim() || !(isAbsolute(path) || path.startsWith("~/")))
            throw new Error(`${field} must be an absolute path.`);
        ret[field] = expandPath(path);
    }
    return ret;
}

export async function readDataDir(configFile: string): Promise<string>
{
    const config = await readDaemonConfig(configFile);
    const value = config.dataDir;
    return typeof value === "string" && value.trim() ? expandPath(value) : dirname(configFile);
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
    for (const name of DAEMON_FIELDS)
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
        if (!DAEMON_FIELDS.includes(field))
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
        if (field === "compactionThresholds")
        {
            const thresholds = typeof value === "string" ? value.split(",").map(Number) : [];
            if (![2, 3].includes(thresholds.length) || thresholds.some((item, index) => !Number.isSafeInteger(item)
                || item < 1 || item < (thresholds[index - 1] ?? 0)))
                throw new Error("Compaction thresholds must be two or three increasing positive token counts.");
        }
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
            await writePrivateFile(configFile, DEFAULT_CONFIG_TEMPLATE);
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

export const DEFAULT_CONFIG_TEMPLATE = `dataDir: ~/.local/share/autonom
devinCommand: devin
executionTimeout: 30m
compactOnResume: false
offlineStartAfter: 1h
offlineCompactAfter: 1h
compactionThresholds: 1,2,3
router:
  type: openrouter
  key: ""
  url: https://openrouter.ai
  name: OpenRouter
  referer: ""
  title: ""
`;

const DAEMON_FIELDS = [
    "dataDir",
    "devinCommand",
    "compactOnResume",
    "offlineStartAfter",
    "offlineCompactAfter",
    "compactionThresholds",
    "executionTimeout",
];
