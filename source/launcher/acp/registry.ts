import { object, readPrivateFile, writePrivateFile } from "../config";

import { homedir } from "node:os";
import { join } from "node:path";

export function defaultAgentRegistryPath(): string
{
    return join(homedir(), ".windsurf", "acp", "registry.json");
}

function agentRegistry(source: string): { version: string; agents: Record<string, unknown>[] }
{
    const ret = JSON.parse(source);
    if (ret?.version !== "1.0.0" || !Array.isArray(ret.agents)
        || !ret.agents.every((agent: unknown) => typeof object(agent)?.id === "string")
        || ret.agents.filter((agent: Record<string, unknown>) => agent.id === "devin-autonom").length > 1)
        throw new Error("Unsupported ACP registry.");

    return ret;
}

export async function installAutonomAgent(
    repository: string,
    socketPath: string,
    path = defaultAgentRegistryPath()
): Promise<void>
{
    const source = await readPrivateFile(path, 512 * 1024).catch((error) =>
    {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT")
            throw error;

        return '{"version":"1.0.0","agents":[]}';
    });
    const registry = agentRegistry(source);
    const entry = {
        id: "devin-autonom",
        name: "Autonom",
        version: "0.1.0",
        description: "Devin Local with daemon-owned Autonom sessions and scheduled wakes.",
        license: "AGPL-3.0-only",
        icon: "https://cdn.jsdelivr.net/gh/cetio/autonom@daemon/assets/icons/autonom-fill.svg",
        distribution: { binary: { "linux-x86_64": {
            archive: "",
            cmd: "python3",
            args: [join(repository, "source", "launcher", "acp", "server.py"), "--socket", socketPath],
        } } },
    };
    const recordPath = `${path}.autonom.orig`;
    const previous = await readPrivateFile(recordPath, 2 * 1024 * 1024).catch((error) =>
    {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT")
            throw error;

        return undefined;
    });
    const installed = registry.agents.find((agent) => agent.id === entry.id);
    const record = previous ? JSON.parse(previous) : { entry: null };
    if (previous && JSON.stringify(installed ?? null) !== JSON.stringify(record.entry))
        throw new Error("Autonom ACP entry changed externally; refusing to overwrite it.");

    const index = registry.agents.findIndex((agent) => agent.id === entry.id);
    if (index === -1)
        registry.agents.push(entry);
    else
        registry.agents[index] = entry;

    const next = JSON.stringify(registry, null, 4) + "\n";
    await writePrivateFile(recordPath, JSON.stringify({ entry }));
    await writePrivateFile(path, next);
}

