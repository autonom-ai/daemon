module daemon.interop.bridge;

import daemon.exception;
import daemon.interop.access;
import daemon.interop.execution;
import daemon.interop.process;
import daemon.interop.session;
import daemon.storage;

import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDWR;
import core.sys.posix.signal : SIGKILL;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : endsWith, sort;
import std.array : join;
import std.conv : to;
import std.file;
import std.path : baseName, buildPath, dirName;
import std.process;
import std.stdio : File;
import std.uuid;

abstract class Bridge
{
private:
    struct Observed
    {
        string connection;
        string directory;
        bool active;
    }

    Session[string] sessions;
    Execution[string] executions;
    bool[string] collected;
    bool[string] removed;
    Observed[string] observed;
    MonoTime[string] connections;

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

    void checkCapacity()
    {
        size_t active;
        foreach (entry; executions)
            active += entry.running;

        if (active >= 8)
            throw new ConflictException("Execution capacity reached");
    }

    Execution launchProcess(
        Execution execution,
        string[] arguments,
        Execution prerequisite = null,
        Execution dependency = null,
        string[string] environment = null
    )
    {
        checkCapacity();
        string[string] child = childEnvironment();
        child.remove("AUTONOM_CLIENT_TOKEN");
        child["AUTONOM_RUN_TOKEN"] = access.begin(execution);
        foreach (name, value; environment)
            child[name] = value;

        execution.start(
            [command]~arguments,
            child,
            execution.kind == ExecutionKind.Remove ? 10.seconds : executionTimeout,
            prerequisite,
            dependency
        );
        executions[execution.id] = execution;
        return execution;
    }

    Execution launchTask(
        Execution execution,
        ExecutionTask task,
        Execution prerequisite = null,
        Execution dependency = null
    )
    {
        checkCapacity();
        execution.start(task, executionTimeout, prerequisite, dependency);
        executions[execution.id] = execution;
        return execution;
    }

public:
    Access access;
    Duration executionTimeout = 30 * 60.seconds;
    const string command;
    const string logDir;
    const string executionDir;

    this(string command, string logDir)
    {
        this.command = command;
        this.logDir = logDir;
        access = new Access(dirName(logDir));
        executionDir = buildPath(dirName(logDir), "executions");
        if ((exists(logDir) && isSymlink(logDir)) ||
            (exists(executionDir) && isSymlink(executionDir)))
            throw new Exception("Backend storage must not be a symlink");

        if (!exists(executionDir))
            return;

        foreach (DirEntry entry; dirEntries(executionDir, SpanMode.shallow))
        {
            if (!entry.name.endsWith(".json"))
                continue;

            if (!entry.isFile || entry.isSymlink)
                throw new Exception("Execution record must be a regular file");

            Execution execution = Execution.load(executionDir, logDir, entry.name.baseName[0..$-5]);
            executions[execution.id] = execution;
        }
    }

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

        if (Session* found = id in sessions)
            return *found;
        if (id in observed)
            return session(id);

        return null;
    }

    Execution execution(string id)
    {
        Session.validateId(id);
        Execution* found = id in executions;
        return found is null ? null : *found;
    }

    bool isRemoved(string id)
        => (id in removed) !is null;

    bool observedSession(string id)
        => (id in observed) !is null;

    bool observedActive(string id)
    {
        Observed* found = id in observed;
        return found !is null && found.active;
    }

    string observedConnection(string id)
    {
        Observed* found = id in observed;
        return found is null ? null : found.connection;
    }

    string observedDirectory(string id)
    {
        Observed* found = id in observed;
        return found is null ? null : found.directory;
    }

    void observeConnection(string connection, string[] ids, string[string] directories,
        bool[string] active, bool closed)
    {
        try
            UUID(connection);
        catch (Exception)
            throw new InvalidInputException("Invalid connection ID");

        if (closed)
        {
            connections.remove(connection);
            foreach (id; observed.keys)
            {
                if (observed[id].connection == connection)
                    observed.remove(id);
            }
            return;
        }

        connections[connection.idup] = MonoTime.currTime;
        foreach (id; ids)
        {
            Session.validateId(id);
            observed[id.idup] = Observed(
                connection.idup,
                directories.get(id, null),
                active.get(id, false)
            );
        }
    }

    void sweepObserved()
    {
        MonoTime cutoff = MonoTime.currTime - 30.seconds;
        foreach (connection; connections.keys)
        {
            if (connections[connection] < cutoff)
                connections.remove(connection);
        }

        foreach (id; observed.keys)
        {
            if (observed[id].connection !in connections)
                observed.remove(id);
        }
    }

    string[] sessionIds()
    {
        bool[string] ids;
        foreach (id; access.ids)
            ids[id] = true;
        foreach (id, entry; observed)
            ids[id] = true;

        return ids.keys;
    }

    Execution[] listExecutions(string directory = null)
    {
        Execution[] ret;
        foreach (execution; executions)
        {
            if (!directory.length || execution.workspace == directory)
                ret ~= execution;
        }

        ret.sort!((left, right) => left.createdAt < right.createdAt);
        return ret;
    }

    Execution authenticate(string token, string id, bool bind = false)
    {
        Execution ret = access.authenticate(token, id, bind);
        if (ret !is null)
            session(id).bindExecution(ret);

        return ret;
    }

    string[] collect()
    {
        sweepObserved();
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
                    access.forget(id);
                    removed[id] = true;
                }
                else if (id !in removed)
                {
                    if (execution.kind == ExecutionKind.Start || execution.kind == ExecutionKind.Print)
                        access.remember(id, execution.trusted);

                    Session session = this.session(id);
                    if (session.execution is null || session.execution.createdAt <= execution.createdAt)
                        session.bindExecution(execution);
                }
            }

            collected[execution.id] = true;
        }

        access.collect();
        return removed.keys;
    }

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

    abstract bool online(string id);

    abstract Execution remove(string id);

    string logPath(string id) const
        => buildPath(logDir, id~".log");

    File openLog(string id)
    {
        Session.validateId(id);
        mkdirRecurse(logDir);
        return openFile(logPath(id), O_RDWR | O_CREAT | O_APPEND);
    }

    void removeLog(string id)
    {
        Session.validateId(id);
        string path = logPath(id);
        if (exists(path))
            std.file.remove(path);
    }

    string run(string[] arguments, string directory = null, Duration timeout = 2.seconds)
    {
        File output = File.tmpfile();
        File errors = File.tmpfile();
        scope(exit)
        {
            output.close();
            errors.close();
        }

        Config options = Config.newEnv | Config.retainStdout | Config.retainStderr;
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
        bool finished;
        scope(failure)
        {
            if (!finished)
            {
                signal(process, SIGKILL);
                wait(process);
            }
        }

        MonoTime deadline = MonoTime.currTime + timeout;
        typeof(tryWait(Pid.init)) result;
        while (!(result = tryWait(process)).terminated)
        {
            if (MonoTime.currTime >= deadline)
                throw new BackendException("CLI command timed out");

            Thread.sleep(10.msecs);
        }

        finished = true;
        if (result.status != 0)
            throw new BackendException("CLI command failed (exit "~result.status.to!string~")");

        output.rewind();
        if (output.size > 1024 * 1024)
            throw new Exception("CLI response is too large");

        return cast(string)output.byChunk(4096).join;
    }
}
