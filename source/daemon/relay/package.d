module daemon.relay;

import daemon.config;
import daemon.interop.acp;
import daemon.relay.agent;

import std.file : read;
import std.path : buildPath;
import std.process : environment;
import std.stdio : stderr, stdin, stdout;
import std.string : startsWith, strip;
import std.uuid : randomUUID;

int main(string[] args)
{
    string devin = environment.get("AUTONOM_DEVIN", "devin");
    string configPath;
    for (size_t i = 1; i < args.length; i++)
    {
        if (args[i] == "--devin" && i + 1 < args.length)
            devin = args[++i];
        else if (args[i] == "--config" && i + 1 < args.length)
            configPath = args[++i];
    }

    RelayAgent agent;
    string dataDir;
    if (configPath.length)
    {
        try
        {
            Config config = new Config(configPath);
            string connection = randomUUID().toString();
            agent = new RelayAgent(
                strip((cast(char[])read(buildPath(config.dataDir, "client.token"))).idup),
                environment.get("AUTONOM_PORT", "8080"),
                connection,
                buildPath(config.dataDir, "acp", connection~".sock")
            );
            dataDir = config.dataDir;
        }
        catch (Exception error)
        {
            stderr.writeln("autonom-acp: control disabled: ", error.msg);
            agent = new RelayAgent("", environment.get("AUTONOM_PORT", "8080"), null, null);
        }
    }
    else
        agent = new RelayAgent("", environment.get("AUTONOM_PORT", "8080"), null, null);

    agent.begin();
    string[string] child = environment.toAA;
    foreach (name; child.keys)
    {
        if (name.startsWith("ACP_") || name.startsWith("AUTONOM_CLIENT_") ||
            name.startsWith("AUTONOM_RUN_") || name.startsWith("AUTONOM_MCP_") ||
            name.startsWith("AUTONOM_RELAY_"))
            child.remove(name);
    }
    if (dataDir.length)
        child["AUTONOM_DATA_DIR"] = dataDir;

    int status = runRelay(
        [devin, "acp"],
        child,
        null,
        (bool clientToAgent, string frame) { agent.frame(clientToAgent, frame); },
        agent.injection,
        stdin,
        stdout,
        agent.linked() ? &agent.rewrite : null
    );
    agent.close();
    return status;
}
