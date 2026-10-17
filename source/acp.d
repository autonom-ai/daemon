module acp;

import daemon.config : Config;
import daemon.interop.acp;
import daemon.interop.devin.desktop;
import daemon.interop.process : childEnvironment;

import std.file : read;
import std.path : buildPath;
import std.process : environment;
import std.stdio : stderr, stdin, stdout;
import std.string : strip;
import std.uuid : randomUUID;

int main(string[] args)
{
    string command = environment.get("AUTONOM_DEVIN", "devin");
    string configPath;
    for (size_t i = 1; i < args.length; i++)
    {
        if (args[i] == "--devin" && i + 1 < args.length)
            command = args[++i];
        else if (args[i] == "--config" && i + 1 < args.length)
            configPath = args[++i];
        else
            throw new Exception("Expected --devin <command> or --config <file>");
    }
    string token;
    string data;
    if (configPath.length)
    {
        Config config = new Config(configPath);
        data = config.dataDir;
        token = strip((cast(char[])read(buildPath(data, "client.token"))).idup);
    }
    string[string] child = childEnvironment();
    if (data.length)
        child["AUTONOM_DATA_DIR"] = data;
    AcpClient agent = new AcpClient([command, "acp"], child, null, stderr);
    scope(exit) agent.close();
    string id = randomUUID().toString();
    Desktop desktop = new Desktop(agent, token, environment.get("AUTONOM_PORT", "8080"), id,
        data.length ? buildPath(data, "acp", id~".sock") : null);
    scope(exit) desktop.close();
    return agent.relay(stdin, stdout);
}
