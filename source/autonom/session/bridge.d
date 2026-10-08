module autonom.session.bridge;

import autonom.session.session : Session;

import core.sys.posix.unistd : setpgid;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : any, startsWith;
import std.array : join;
import std.conv : to;
import std.exception : enforce;
import std.process : environment, kill, PROCESS_CONFIG = Config, Pid, spawnProcess, tryWait, wait;
import std.stdio : File;

abstract class Bridge
{
private:
    static bool createProcessGroup() nothrow @nogc @trusted
        => setpgid(0, 0) == 0;

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

    abstract Session session(string id);

    abstract void remove(string id);

    Pid spawn(string[] arguments, string directory, File output)
    {
        PROCESS_CONFIG options = PROCESS_CONFIG.newEnv;
        options.preExecFunction = &createProcessGroup;
        return spawnProcess(
            [command]~arguments,
            File("/dev/null", "r"),
            output,
            output,
            childEnvironment(),
            options,
            directory
        );
    }

    string run(string[] arguments, string directory = null, Duration timeout = 120.seconds)
    {
        File output = File.tmpfile();
        File errors = File.tmpfile();
        scope(exit)
        {
            output.close();
            errors.close();
        }

        Pid process = spawnProcess(
            [command]~arguments,
            File("/dev/null", "r"),
            output,
            errors,
            childEnvironment(),
            PROCESS_CONFIG.newEnv | PROCESS_CONFIG.retainStdout | PROCESS_CONFIG.retainStderr,
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
}
