import { object } from "./parse";
import { readPrivateFile, writePrivateFile } from "./storage";

import { parseDocument, stringify as stringifyYaml } from "yaml";

import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

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
    return path === "~" ? homedir() : path.startsWith("~/") ? join(homedir(), path.slice(2)) : resolve(path);
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
