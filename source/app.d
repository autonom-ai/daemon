module app;

import daemon.acp;
import daemon.api;

import serverino.daemon : Daemon;
import serverino;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm : canFind;
import std.base64 : Base64;
import std.conv : to;
import std.file : thisExePath;
import std.getopt : defaultGetoptPrinter, getopt, GetOptException, GetoptResult;
import std.path : baseName;
import std.process : environment;
import std.socket : AddressFamily, InternetAddress, Socket, SocketType;
import std.stdio : stderr, stdout, writeln;
import std.string : split;

mixin ServerinoLoop!(daemon.api, apiModules);

int main(string[] args)
{
    // Serverino dynamic worker processes inherit command line arguments via SERVERINO_ARGS
    if (environment.get("SERVERINO_ARGS") !is null)
        args = (cast(string)Base64.decode(environment.get("SERVERINO_ARGS"))).split("\0");

    // Dynamic Serverino worker processes jump straight to worker request handling
    if (ServerinoProcess.isDynamicComponent)
        return mainServerinoLoop!OnMainThread(args);

    // Master / daemon process argument parsing
    string configPath;
    ushort port = 0;
    string devinCmd;
    bool acpMode = false;
    bool helpWanted = false;
    bool versionWanted = false;
    GetoptResult helpInfo;

    try
    {
        helpInfo = getopt(
            args,
            "config|c", "Path to configuration YAML file", &configPath,
            "port|p", "Port for HTTP API listener (default: 8080)", &port,
            "devin", "Command or path to Devin CLI executable (default: devin)", &devinCmd,
            "acp", "Serve ACP directly over stdio (dual-host mode)", &acpMode,
            "version|v", "Print version information and exit", &versionWanted
        );
        helpWanted = helpInfo.helpWanted;
    }
    catch (GetOptException e)
    {
        stderr.writeln("Error: ", e.msg);
        stderr.writeln("Run with --help for usage information.");
        return 1;
    }

    if (versionWanted)
    {
        stdout.writeln("Autonom 0.1.0");
        return 0;
    }

    if (helpWanted)
    {
        defaultGetoptPrinter(
            "Autonom state and session API daemon.\n\n"~
            "Usage: autonom [options]\n\n"~
            "Options:",
            helpInfo.options
        );
        return 0;
    }

    if (configPath.length)
        environment["AUTONOM_CONFIG"] = configPath;
    if (port != 0)
        environment["AUTONOM_PORT"] = port.to!string;
    if (devinCmd.length)
        environment["AUTONOM_DEVIN"] = devinCmd;

    // Detect invocation as autonom-acp for backward compatibility
    if (thisExePath.baseName.canFind("acp") || environment.get("AUTONOM_ACP") == "1")
        acpMode = true;

    if (acpMode)
    {
        environment["AUTONOM_ACP"] = "1";
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
    else
    {
        // Normal daemon mode: HTTP API Serverino daemon runs on main thread
        return mainServerinoLoop!OnMainThread(args);
    }
}
