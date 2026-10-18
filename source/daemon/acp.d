module daemon.acp;

import daemon.config : Config;
import daemon.interop.acp.client : AcpClient;
import daemon.interop.devin.desktop : Desktop;
import daemon.interop.devin.hooks : installHooks;
import daemon.interop.devin.process : cliEnvironment;

import core.atomic : atomicLoad, atomicStore;
import core.sys.posix.unistd : symlink;
import std.file : exists, isSymlink, read, remove;
import std.path : baseName, buildPath;
import std.process : environment;
import std.stdio : File, stderr, stdin, stdout;
import std.string : strip, toStringz;
import std.uuid : randomUUID;

/// ACP Host Connection encapsulating Desktop stdio and authenticated control socket.
class AcpHostConnection
{
private:
    string id;
    AcpClient agent;
    Desktop desktop;
    File peerInput;
    File peerOutput;
    string daemonSockPath;
    shared bool running;

public:
    this(
        AcpClient agent,
        File peerInput,
        File peerOutput,
        string token = null,
        string port = "8080",
        string id = null,
        string socketPath = null,
        string daemonSockPath = null
    )
    {
        this.id = id.length ? id : randomUUID().toString();
        this.agent = agent;
        this.peerInput = peerInput;
        this.peerOutput = peerOutput;
        this.daemonSockPath = daemonSockPath;
        this.desktop = new Desktop(agent, token, port, this.id, socketPath);

        if (socketPath.length && daemonSockPath.length)
        {
            try
            {
                if (exists(daemonSockPath) || isSymlink(daemonSockPath))
                    remove(daemonSockPath);
                symlink(baseName(socketPath).toStringz, daemonSockPath.toStringz);
            }
            catch (Exception)
            { }
        }
    }

    int run()
    {
        atomicStore(running, true);
        scope(exit)
            close();
        return agent.relay(peerInput, peerOutput);
    }

    void close()
    {
        if (!atomicLoad(running))
            return;
        atomicStore(running, false);

        if (daemonSockPath.length)
        {
            try
            {
                if (exists(daemonSockPath) || isSymlink(daemonSockPath))
                    remove(daemonSockPath);
            }
            catch (Exception)
            { }
        }

        if (desktop !is null)
            desktop.close();
        if (agent !is null)
            agent.close();
    }
}

/// In-Daemon ACP Server Host runner.
int runAcpHost(string devinCommand = null, string configPath = null)
{
    string command = devinCommand.length ? devinCommand : environment.get("AUTONOM_DEVIN", "devin");
    string token;
    string data;

    try
    {
        Config config = Config.get(configPath);
        if (config !is null)
        {
            data = config.dataDir;
            string tokenFile = buildPath(data, "client.token");
            if (exists(tokenFile))
                token = strip((cast(char[])read(tokenFile)).idup);
        }
    }
    catch (Exception)
    { }

    installHooks();
    string[string] child = cliEnvironment();
    if (data.length)
        child["AUTONOM_DATA_DIR"] = data;

    AcpClient agent = new AcpClient([command, "acp"], child, null, stderr);
    scope(exit)
        agent.close();

    string port = environment.get("AUTONOM_PORT", "8080");
    string id = randomUUID().toString();
    string socketPath = data.length ? buildPath(data, "acp", id~".sock") : null;
    string daemonSockPath = data.length ? buildPath(data, "acp", "daemon.sock") : null;

    AcpHostConnection host = new AcpHostConnection(agent, stdin, stdout, token, port, id, socketPath, daemonSockPath);
    scope(exit)
        host.close();

    return host.run();
}
