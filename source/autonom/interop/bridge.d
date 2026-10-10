module autonom.interop.bridge;

import autonom.exception : BackendFailure, Conflict;
import autonom.interop.execution : Execution, ExecutionKind, ExecutionStatus;
import autonom.interop.session : Session;
import autonom.storage : openFile;

import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDWR;
import core.sys.posix.signal : SIGKILL;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : any, endsWith, sort, startsWith;
import std.array : join;
import std.conv : to;
import std.exception : enforce;
import std.file : DirEntry, SpanMode, dirEntries, exists, isSymlink, mkdirRecurse, removeFile = remove;
import std.path : baseName, buildPath, dirName;
import std.process : environment, PROCESS_CONFIG = Config, Pid, spawnProcess, tryWait, wait;
import std.stdio : File;
import std.uuid : randomUUID;

/// Contract for a CLI-backed agent bridge.
abstract class Bridge
{
private:
    Session[string] sessions;
    Execution[string] executions;
    bool[string] collected;
    bool[string] removed;

    string[string] childEnvironment() const
    {
        string[string] ret = environment.toAA();
        foreach (name; ret.keys)
        {
            if (scrubPrefixes.any!(prefix => name.startsWith(prefix)))
                ret.remove(name);
        }

        return ret;
    }

protected:
    abstract Session createSession(string id);

    Execution newExecution(
        ExecutionKind kind,
        string directory,
        string model,
        string sessionId = null
    )
    {
        return new Execution(
            executionDir,
            logDir,
            randomUUID().toString(),
            kind,
            directory,
            model,
            sessionId
        );
    }

    /// Spawns the session CLI process, capturing its output in the execution and session logs.
    Execution launch(Execution execution, string[] arguments, Execution prerequisite = null)
    {
        size_t active;
        foreach (entry; executions)
            active += entry.running;

        enforce!Conflict(active < 8, "Execution capacity reached");
        execution.start(
            [command]~arguments,
            childEnvironment(),
            execution.kind == ExecutionKind.Remove ? 10.seconds : 120.seconds,
            prerequisite
        );
        executions[execution.id] = execution;
        return execution;
    }

public:
    const string command;
    const string logDir;
    const string executionDir;
    const string[] scrubPrefixes;

    this(string command, string logDir, const string[] scrubPrefixes = null)
    {
        this.command = command;
        this.logDir = logDir;
        this.scrubPrefixes = scrubPrefixes;
        executionDir = buildPath(dirName(logDir), "executions");
        enforce(!(exists(logDir) && isSymlink(logDir)) &&
            !(exists(executionDir) && isSymlink(executionDir)), "Backend storage must not be a symlink");
        if (!exists(executionDir))
            return;

        foreach (DirEntry entry; dirEntries(executionDir, SpanMode.shallow))
        {
            if (!entry.name.endsWith(".json"))
                continue;

            enforce(entry.isFile && !entry.isSymlink, "Execution record must be a regular file");
            Execution execution = Execution.load(executionDir, logDir, entry.name.baseName[0..$-5]);
            executions[execution.id] = execution;
        }
    }

    /// Gets the canonical session handle for the given ID, creating it on first use.
    Session session(string id)
    {
        Session.validateId(id);
        if (Session* found = id in sessions)
            return *found;

        Session ret = createSession(id);
        sessions[ret.id] = ret;
        return ret;
    }

    Session findSession(string id)
    {
        Session.validateId(id);
        if (id in removed)
            return null;

        Session* found = id in sessions;
        return found is null ? null : *found;
    }

    Execution execution(string id)
    {
        Session.validateId(id);
        Execution* found = id in executions;
        return found is null ? null : *found;
    }

    bool isRemoved(string id)
        => (id in removed) !is null;

    string[] collect()
    {
        Execution[] ready;
        foreach (execution; executions)
        {
            if (!execution.running && execution.id !in collected)
                ready ~= execution;
        }

        ready.sort!((left, right)
        {
            return left.createdAt < right.createdAt;
        });
        foreach (execution; ready)
        {
            execution.wait();
            string id = execution.sessionId;
            if (id.length)
            {
                if (execution.kind == ExecutionKind.Remove && execution.status == ExecutionStatus.Succeeded)
                {
                    removeLog(id);
                    sessions.remove(id);
                    removed[id] = true;
                }
                else if (id !in removed)
                {
                    Session session = this.session(id);
                    if (session.execution is null || session.execution.createdAt <= execution.createdAt)
                        session.bindExecution(execution);
                }
            }

            collected[execution.id] = true;
        }

        return removed.keys;
    }

    /// Stops every session process owned by this bridge, including unprofiled executions.
    void stopSessions()
    {
        foreach (execution; executions)
            execution.requestStop();
    }

    void close()
    {
        Exception failure;
        foreach (execution; executions)
        {
            try
                execution.requestStop();
            catch (Exception error)
            {
                if (failure is null)
                    failure = error;
            }
        }

        foreach (execution; executions)
        {
            try
                execution.wait();
            catch (Exception error)
            {
                if (failure is null)
                    failure = error;
            }
        }

        if (failure !is null)
            throw failure;
    }

    /// Reports whether the backend considers the session active.
    abstract bool online(string id);

    /// Removes the backend session and its local artifacts.
    abstract Execution remove(string id);

    /// Gets the path of the session log.
    string logPath(string id) const
        => buildPath(logDir, id~".log");

    /// Opens the session log for appending.
    File openLog(string id)
    {
        Session.validateId(id);
        mkdirRecurse(logDir);
        return openFile(logPath(id), O_RDWR | O_CREAT | O_APPEND);
    }

    /// Removes the session log when present.
    void removeLog(string id)
    {
        Session.validateId(id);
        string path = logPath(id);
        if (exists(path))
            removeFile(path);
    }

    /// Runs a short CLI metadata command to completion and returns its stdout.
    string run(string[] arguments, string directory = null, Duration timeout = 2.seconds)
    {
        File output = File.tmpfile();
        File errors = File.tmpfile();
        scope(exit)
        {
            output.close();
            errors.close();
        }

        PROCESS_CONFIG options = PROCESS_CONFIG.newEnv | PROCESS_CONFIG.retainStdout | PROCESS_CONFIG.retainStderr;
        options.preExecFunction = &Execution.createProcessGroup;
        Pid process = spawnProcess(
            [command]~arguments,
            File("/dev/null", "r"),
            output,
            errors,
            childEnvironment(),
            options,
            directory
        );
        bool finished;
        scope(failure)
        {
            if (!finished)
            {
                Execution.signal(process, SIGKILL);
                wait(process);
            }
        }

        MonoTime deadline = MonoTime.currTime + timeout;
        typeof(tryWait(Pid.init)) result;
        while (!(result = tryWait(process)).terminated)
        {
            enforce!BackendFailure(MonoTime.currTime < deadline, "CLI command timed out");
            Thread.sleep(10.msecs);
        }

        finished = true;
        enforce!BackendFailure(result.status == 0, "CLI command failed (exit "~result.status.to!string~")");
        output.rewind();
        enforce(output.size <= 1024 * 1024, "CLI response is too large");
        return cast(string)output.byChunk(4096).join;
    }
}
