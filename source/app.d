module app;

import daemon.acp;
import daemon.api;

import serverino.daemon : Daemon;
import serverino;

import core.thread : Thread;
import core.time : msecs;
import std.base64 : Base64;
import std.conv : to;
import std.file : exists, thisExePath;
import std.getopt : getopt, GetOptException, GetoptResult;
import std.path : buildPath, dirName;
import std.process : environment, Pid, spawnProcess, wait;
import std.socket : AddressFamily, InternetAddress, Socket, SocketType;
import std.stdio : File, stderr, stdout, writeln;
import std.string : split;

mixin ServerinoLoop!(daemon.api, apiModules);

enum autonomVersion = "0.1.0";

int main(string[] args)
{
    // Serverino dynamic worker processes inherit command line arguments via SERVERINO_ARGS
    if (environment.get("SERVERINO_ARGS") !is null)
        args = (cast(string)Base64.decode(environment.get("SERVERINO_ARGS"))).split("\0");

    // Dynamic Serverino worker processes jump straight to worker request handling
    if (ServerinoProcess.isDynamicComponent)
        return mainServerinoLoop!OnMainThread(args);

    return dispatch(args);
}

/// Route one command to the daemon, the ACP host, or an installed helper.
private int dispatch(string[] args)
{
    if (args.length < 2)
        return runDaemon(args, args[1..$], false);

    switch (args[1])
    {
        case "daemon":
            return runDaemon(args, args[2..$], false);
        case "acp":
            return runDaemon(args, args[2..$], true);
        case "mcp":
            return runHelper("MCP proxy", ["source", "mcp", "server.py"], args[2..$]);
        case "hook":
            return runHelper("hook", ["templates", "hook.py"], args[2..$]);
        case "help", "--help", "-h":
            usage(stdout);
            return 0;
        case "version", "--version", "-v":
            stdout.writeln("Autonom ", autonomVersion);
            return 0;
        default:
            stderr.writeln("Error: unknown command '", args[1], "'.");
            usage(stderr);
            return 1;
    }
}

/// Run the HTTP daemon, the ACP host, or ensure a configured daemon listens.
private int runDaemon(string[] args, string[] options, bool acpMode)
{
    string configPath;
    ushort port = 0;
    string devinCmd;
    bool ensure = false;
    bool versionWanted = false;
    GetoptResult helpInfo;
    // getopt skips the program name, so the subcommand options carry one.
    string[] parsed = ["autonom"] ~ options;

    try
    {
        helpInfo = getopt(
            parsed,
            "config|c", "Path to configuration YAML file", &configPath,
            "port|p", "Port for HTTP API listener (default: 8080)", &port,
            "devin", "Command or path to Devin CLI executable (default: devin)", &devinCmd,
            "ensure", "Ensure the configured daemon is listening", &ensure,
            "version|v", "Print version information and exit", &versionWanted
        );
    }
    catch (GetOptException e)
    {
        stderr.writeln("Error: ", e.msg);
        stderr.writeln("Run with --help for usage information.");
        return 1;
    }

    if (versionWanted)
    {
        stdout.writeln("Autonom ", autonomVersion);
        return 0;
    }

    if (helpInfo.helpWanted)
    {
        usage(stdout);
        return 0;
    }

    if (configPath.length)
        environment["AUTONOM_CONFIG"] = configPath;
    if (port != 0)
        environment["AUTONOM_PORT"] = port.to!string;
    if (devinCmd.length)
        environment["AUTONOM_DEVIN"] = devinCmd;

    if (acpMode)
        return runAcp(args, devinCmd, configPath);

    if (ensure)
        return runHelper("daemon", ["source", "mcp", "server.py"], ["--ensure"]);

    return mainServerinoLoop!OnMainThread(args);
}

/// Serve ACP over stdio, starting a daemon when none is listening.
private int runAcp(string[] args, string devinCmd, string configPath)
{
    ushort listenPort = environment.get("AUTONOM_PORT", "8080").to!ushort;

    bool portInUse = false;
    try
    {
        Socket probe = new Socket(AddressFamily.INET, SocketType.STREAM);
        scope(exit)
            probe.close();
        probe.blocking = true;
        probe.connect(new InternetAddress("127.0.0.1", listenPort));
        portInUse = true;
    }
    catch (Exception)
        portInUse = false;

    bool startedDaemon = false;
    if (!portInUse)
    {
        mainServerinoLoop!OnSecondaryThread(args);
        startedDaemon = true;

        // Wait briefly for Serverino HTTP daemon listener to become available
        for (size_t attempt = 0; attempt < 100; attempt++)
        {
            try
            {
                Socket probe = new Socket(AddressFamily.INET, SocketType.STREAM);
                scope(exit)
                    probe.close();
                probe.blocking = true;
                probe.connect(new InternetAddress("127.0.0.1", listenPort));
                break;
            }
            catch (Exception)
                Thread.sleep(20.msecs);
        }
    }

    // Run ACP Server Host on main thread
    int ret = daemon.acp.runAcpHost(devinCmd, configPath);

    // On ACP termination, clean up Serverino daemon process if started by us
    if (startedDaemon)
    {
        try
            Daemon.shutdown();
        catch (Exception)
        { }
    }

    return ret;
}

/// Run an installed helper with the inherited standard streams and exit status.
private int runHelper(string label, string[] parts, string[] args)
{
    string script = buildPath([resourceRoot()] ~ parts);
    if (!exists(script))
    {
        stderr.writeln("Error: the Autonom ", label, " is not installed at ", script, ".");
        return 1;
    }

    try
    {
        Pid process = spawnProcess(["python3", script] ~ args);
        return wait(process);
    }
    catch (Exception)
    {
        stderr.writeln("Error: Python 3 is required to run the Autonom ", label, ".");
        return 1;
    }
}

/// The installed root that owns the runtime files beside the command.
private string resourceRoot()
    => dirName(dirName(thisExePath));

private void usage(File stream)
{
    stream.writeln("Autonom ", autonomVersion, " - state and session API daemon.");
    stream.writeln();
    stream.writeln("Usage: autonom <command> [options]");
    stream.writeln();
    stream.writeln("Commands:");
    stream.writeln("  daemon    Run the HTTP daemon in the foreground.");
    stream.writeln("  acp       Serve ACP over stdio for Devin Desktop.");
    stream.writeln("  mcp       Run the coordination MCP proxy over stdio.");
    stream.writeln("  hook      Forward a Devin CLI hook event to the daemon.");
    stream.writeln();
    stream.writeln("Options:");
    stream.writeln("  --config <path>  Configuration file.");
    stream.writeln("  --port <port>    HTTP API port.");
    stream.writeln("  --devin <cmd>    Devin CLI executable or path.");
    stream.writeln("  --ensure         Ensure the configured daemon is listening.");
    stream.writeln("  --event <name>   Hook event name.");
    stream.writeln("  --version        Print the version and exit.");
    stream.writeln("  --help           Print this usage and exit.");
}
