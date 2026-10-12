import { readPrivateFile, revision, writePrivateFile } from "./files";
import { record, text } from "../protocol";
import type { ConfigurationState, PermissionMode, Settings } from "../protocol";

import { parse as parseJson } from "jsonc-parser";
import { parseDocument } from "yaml";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import type { WorkspaceConfiguration } from "vscode";

export function readSettings(configuration: Pick<WorkspaceConfiguration, "get">, extensionPath: string): Settings
{
    const configuredRoot = text(configuration.get("rootDirectory"));
    const envRoot = text(process.env.AUTONOM_ROOT);
    const checkoutRoot = resolve(extensionPath, "..");
    const ret: Settings = {
        rootDirectory: configuredRoot ? expand(configuredRoot) : (envRoot ? expand(envRoot) : checkoutRoot),
        configFile: expand(text(configuration.get("configFile"), defaultConfigPath())),
        port: integer(configuration.get("port"), 8080, 1, 65535),
        defaultModel: text(configuration.get("defaultModel"), "swe-2-medium"),
        permissionMode: permissionMode(configuration.get("permissionMode")),
        pollIntervalMs: integer(configuration.get("pollIntervalMs"), 1000, 500, 10000),
        notifyPings: configuration.get("notifyPings") !== false,
    };
    return ret;
}

export function validateSettings(value: unknown): Settings
{
    const settings = record(value);
    if (settings === undefined || !isAbsolute(text(settings.rootDirectory))
        || !isAbsolute(text(settings.configFile)) || typeof settings.notifyPings !== "boolean"
        || typeof settings.port !== "number" || settings.port < 1 || settings.port > 65535
        || !Number.isInteger(settings.port) || typeof settings.pollIntervalMs !== "number"
        || settings.pollIntervalMs < 500 || settings.pollIntervalMs > 10000
        || !text(settings.defaultModel) || !["auto", "accept-edits", "smart", "bypass"].includes(text(settings.permissionMode)))
        throw new Error("Settings require absolute paths, a valid port and model, and a supported permission mode.");
    return settings as Settings;
}

export async function configurationState(workspace: string, configFile: string): Promise<ConfigurationState>
{
    const policyPath = join(workspace, ".devin", "policy.yml");
    const policy = await optionalText(policyPath);
    const document = parseDocument(await optionalText(configFile));
    if (document.errors.length)
        throw new Error("Daemon configuration contains invalid YAML.");
    const daemonValue = record(document.toJS()) ?? {};
    const router = record(daemonValue.router);
    const daemon: Record<string, unknown> = {};
    for (const name of DAEMON_FIELDS)
    {
        if (name in daemonValue)
            daemon[name] = daemonValue[name];
    }
    return {
        workspace,
        installed: await integrationReady(workspace),
        policy,
        policyVersion: revision(policy),
        daemon,
        routerConfigured: Boolean(text(router?.key)),
    };
}

export async function savePolicy(workspace: string, content: string, version: string): Promise<void>
{
    if (content.length > 65536)
        throw new Error("Policy exceeds the configuration size limit.");
    const path = join(workspace, ".devin", "policy.yml");
    if (revision(await optionalText(path)) !== version)
        throw new Error("Policy changed on disk. Reload before saving to avoid overwriting your changes.");
    const document = parseDocument(content);
    const policy = record(document.toJS());
    if (document.errors.length || !Array.isArray(policy?.rules))
        throw new Error("Policy must contain a valid rules list.");
    for (const value of policy.rules)
    {
        const rule = record(value);
        if (rule === undefined || !["allow", "deny", "screen"].includes(text(rule.action)))
            throw new Error("Every policy rule must have an allow, deny, or screen action.");
        if (rule.action === "screen" && (!Array.isArray(rule.models) || !rule.models.length
            || !Array.isArray(rule.questions) || !rule.questions.length))
            throw new Error("Screen rules require models and predicate questions.");
    }
    await writePrivateFile(path, content);
}

export async function saveDaemon(path: string, values: Record<string, unknown>): Promise<void>
{
    await ensureDefaultConfig(path);
    const document = parseDocument(await readPrivateFile(path));
    if (document.errors.length)
        throw new Error("Daemon configuration contains invalid YAML.");
    for (const [field, value] of Object.entries(values))
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
    await writePrivateFile(path, document.toString());
}

export async function configureKey(path: string, key: string): Promise<void>
{
    await ensureDefaultConfig(path);
    const document = parseDocument(await readPrivateFile(path));
    if (document.errors.length || !record(document.toJS())?.router)
        throw new Error("Daemon configuration requires a router mapping.");
    document.setIn(["router", "key"], key);
    await writePrivateFile(path, document.toString());
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

export async function ensureDefaultConfig(path: string): Promise<void>
{
    try
    {
        await readPrivateFile(path);
    }
    catch (error)
    {
        if ((error as NodeJS.ErrnoException).code === "ENOENT")
            await writePrivateFile(path, DEFAULT_CONFIG_TEMPLATE);
        else
            throw error;
    }
}

export async function readRouterKey(path: string): Promise<string>
{
    try
    {
        const content = await readPrivateFile(path);
        const document = parseDocument(content);
        if (document.errors.length)
            return "";
        const daemonValue = record(document.toJS());
        const router = record(daemonValue?.router);
        return text(router?.key);
    }
    catch
    {
        return "";
    }
}

export function defaultConfigPath(): string
{
    return join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), "autonom", "config.yml");
}

export function expand(path: string): string
{
    if (!path)
        return defaultConfigPath();
    return path.startsWith("~/") ? join(homedir(), path.slice(2)) : resolve(path);
}

function permissionMode(value: unknown): PermissionMode
{
    return value === "bypass" || value === "smart" || value === "accept-edits" ? value : "auto";
}

function integer(value: unknown, fallback: number, minimum: number, maximum: number): number
{
    return typeof value === "number" && Number.isInteger(value) && value >= minimum && value <= maximum
        ? value : fallback;
}

async function integrationReady(workspace: string): Promise<boolean>
{
    const hooks = record(parseJson(await optionalText(join(workspace, ".devin", "hooks.v1.json"))) as unknown);
    const mcp = record(parseJson(await optionalText(join(workspace, ".devin", "mcp_config.json"))) as unknown);
    const server = record(record(mcp?.mcpServers)?.["autonom-coord"]);
    if (!Array.isArray(server?.args) || !server.args.some((argument) =>
        typeof argument === "string" && argument.endsWith("source/coord/server.py")))
        return false;
    for (const event of ["PreToolUse", "PostToolUse", "PermissionRequest", "UserPromptSubmit", "SessionStart"])
    {
        const groups = hooks?.[event];
        if (!Array.isArray(groups) || !groups.some((item) =>
        {
            const group = record(item);
            return Array.isArray(group?.hooks) && group.hooks.some((item) =>
                text(record(item)?.command).includes("source/coord/hook.py"));
        }))
            return false;
    }
    return true;
}

async function optionalText(path: string): Promise<string>
{
    try
    {
        return await readPrivateFile(path);
    }
    catch (error)
    {
        if ((error as NodeJS.ErrnoException).code === "ENOENT")
            return "";
        throw error;
    }
}

const DAEMON_FIELDS = [
    "dataDir",
    "devinCommand",
    "compactOnResume",
    "offlineStartAfter",
    "offlineCompactAfter",
    "compactionThresholds",
    "executionTimeout",
];
