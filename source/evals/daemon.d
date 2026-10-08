module evals.daemon;

import evals.client : get, post, waitFor;

import core.time : seconds;
import std.conv : octal;
import std.exception : enforce;
import std.file : mkdirRecurse, readText, rmdirRecurse, setAttributes, tempDir, write;
import std.json : JSONValue;
import std.net.curl : CurlException;
import std.path : buildPath;
import std.process : Config, Pid, kill, spawnProcess, tryWait, wait;
import std.stdio : File, stdin;
import std.uuid : randomUUID;

public:

class Daemon
{
private:
    Pid process;
    File output;

public:
    const string directory;
    const string workspace;

    this()
    {
        directory = buildPath(tempDir(), "autonom-eval-"~randomUUID().toString());
        workspace = buildPath(directory, "workspace");
        mkdirRecurse(workspace);
        scope(failure)
            close();

        string scripts = buildPath(directory, ".devin");
        mkdirRecurse(scripts);
        string command = buildPath(scripts, "cli");
        write(command, "#!/bin/sh\nexec \"${AUTONOM_EVAL_CLI:-devin}\" --respect-workspace-trust false \"$@\"\n");
        setAttributes(command, octal!"700");
        string configuration = buildPath(directory, "config.yml");
        write(configuration, "dataDir: data\ndevinCommand: ./.devin/cli\n");
        string log = buildPath(directory, "daemon.log");
        output = File(log, "w");
        process = spawnProcess(
            ["bin/autonom-daemon"],
            stdin,
            output,
            output,
            ["AUTONOM_CONFIG": configuration, "AUTONOM_PORT": "18080"],
            Config.retainStdin | Config.retainStdout | Config.retainStderr
        );
        enforce(waitFor(delegate bool()
        {
            enforce(!tryWait(process).terminated, readText(log));
            try
                return get("/api/health")["pid"].integer == process.processID;
            catch (CurlException)
                return false;
        }, 5.seconds), "Daemon did not become healthy");
    }

    void stop()
    {
        post("/api/stop", JSONValue.emptyObject, 202);
        enforce(waitFor(delegate bool()
        {
            return tryWait(process).terminated;
        }, 5.seconds), "Daemon did not stop");
        enforce(wait(process) == 0, "Daemon did not exit cleanly");
        process = null;
    }

    void close()
    {
        if (process !is null)
        {
            if (!tryWait(process).terminated)
                kill(process);

            wait(process);
            process = null;
        }

        if (output.isOpen)
            output.close();

        rmdirRecurse(directory);
    }
}
