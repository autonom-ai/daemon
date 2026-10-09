module autonom.interop.bridge;

import autonom.interop.session : Session;
import autonom.storage : openFile;

import core.stdc.errno : errno, ESRCH;
import core.sys.linux.sys.prctl : prctl, PR_SET_PDEATHSIG;
import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDWR;
import core.sys.posix.signal : killGroup = kill, SIGTERM;
import core.sys.posix.unistd : setpgid;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : any, startsWith;
import std.array : join;
import std.conv : to;
import std.exception : enforce, errnoEnforce;
import std.file : exists, mkdirRecurse, removeFile = remove;
import std.path : buildPath;
import std.process : environment, kill, PROCESS_CONFIG = Config, Pid, spawnProcess, tryWait, wait;
import std.stdio : File;

/// Contract for a CLI-backed agent bridge.
abstract class Bridge
{
private:
    static bool createProcessGroup() nothrow @nogc @trusted
        => setpgid(0, 0) == 0 && prctl(
            PR_SET_PDEATHSIG,
            SIGTERM,
            0,
            0,
            0
        ) == 0;

    string[string] childEnvironment() const
    {
        string[string] ret = environment.toAA();
        foreach (name; ret.keys)
            if (scrubPrefixes.any!(prefix => name.startsWith(prefix)))
                ret.remove(name);

        return ret;
    }

public:
    const string command;
    const string logDir;
    const string[] scrubPrefixes;

    this(string command, string logDir, const string[] scrubPrefixes = null)
    {
        this.command = command;
        this.logDir = logDir;
        this.scrubPrefixes = scrubPrefixes;
    }

    /// Creates a session handle for the given ID.
    abstract Session session(string id);

    /// Reports whether the backend considers the session active.
    abstract bool online(string id);

    /// Removes the backend session and its local artifacts.
    abstract void remove(string id);

    /// Gets the path of the session log.
    string logPath(string id) const
        => buildPath(logDir, id~".log");

    /// Opens the session log for appending.
    File openLog(string id)
    {
        mkdirRecurse(logDir);
        return openFile(logPath(id), O_RDWR | O_CREAT | O_APPEND);
    }

    /// Removes the session log when present.
    void removeLog(string id)
    {
        string path = logPath(id);
        if (exists(path))
            removeFile(path);
    }

    /// Spawns the session CLI process, capturing its output in the session log.
    Pid spawn(string id, string[] arguments, string directory)
    {
        File log = openLog(id);
        scope(exit)
            log.close();

        PROCESS_CONFIG options = PROCESS_CONFIG.newEnv;
        options.preExecFunction = &createProcessGroup;
        return spawnProcess(
            [command]~arguments,
            File("/dev/null", "r"),
            log,
            log,
            childEnvironment(),
            options,
            directory
        );
    }

    /// Runs the CLI to completion and returns its stdout.
    string run(string[] arguments, string directory = null, Duration timeout = 120.seconds)
    {
        File output = File.tmpfile();
        File errors = File.tmpfile();
        scope(exit)
        {
            output.close();
            errors.close();
        }

        PROCESS_CONFIG options = PROCESS_CONFIG.newEnv | PROCESS_CONFIG.retainStdout | PROCESS_CONFIG.retainStderr;
        options.preExecFunction = &createProcessGroup;
        Pid process = spawnProcess(
            [command]~arguments,
            File("/dev/null", "r"),
            output,
            errors,
            childEnvironment(),
            options,
            directory
        );
        scope(failure)
        {
            if (process.processID > 0)
            {
                kill(process);
                wait(process);
            }
        }

        MonoTime deadline = MonoTime.currTime + timeout;
        typeof(tryWait(Pid.init)) result;
        while (!(result = tryWait(process)).terminated)
        {
            enforce(MonoTime.currTime < deadline, "CLI command timed out");
            Thread.sleep(10.msecs);
        }

        errors.rewind();
        enforce(result.status == 0,
            "CLI command failed (exit "~result.status.to!string~"): "~cast(string)errors.byChunk(4096).join);
        output.rewind();
        return cast(string)output.byChunk(4096).join;
    }

    /// Terminates a session process and returns its exit status.
    static int terminate(Pid process)
    {
        errnoEnforce(killGroup(-process.processID, SIGTERM) == 0 || errno == ESRCH, "Could not stop session");
        MonoTime deadline = MonoTime.currTime + 5.seconds;
        typeof(tryWait(Pid.init)) result;
        while (!(result = tryWait(process)).terminated)
        {
            enforce(MonoTime.currTime < deadline, "Session did not stop within the timeout");
            Thread.sleep(10.msecs);
        }

        return result.status;
    }
}
