module daemon.relay;

import daemon.config;
import daemon.interop.acp;
import daemon.relay.agent;

import std.file : read;
import std.path : buildPath;
import std.process : environment;
import std.stdio : stderr;
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
        if (name.startsWith("AUTONOM_CLIENT_") || name.startsWith("AUTONOM_RUN_"))
            child.remove(name);
    }

    int status = runRelay(
        [devin, "acp"],
        child,
        null,
        (bool clientToAgent, string frame) { agent.frame(clientToAgent, frame); },
        agent.injection
    );
    agent.close();
    return status;
}
