module daemon.interop.bridge;

import daemon.config : DaemonConfig = Config;
import daemon.exception;
import daemon.interop.devin.acp;
import daemon.interop.devin.db;
import daemon.interop.metadata : SessionMetadata;
import daemon.interop.acp : AcpClient, AcpException;
import daemon.interop.access;
import daemon.interop.process;
import daemon.interop.session;
import daemon.storage;

import core.stdc.errno : errno, EWOULDBLOCK;
import core.sync.mutex : Mutex;
import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB;
import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDONLY, O_RDWR;
import core.sys.posix.signal : SIGKILL, SIGTERM;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : canFind, endsWith, sort;
import std.array : join;
import std.conv : octal, to;
import std.datetime : Clock, UTC;
import std.exception : ErrnoException;
import std.file;
import std.json : JSONValue;
import std.path : baseName, buildPath, dirName;
import std.process;
import std.stdio : File;
import std.uuid;

enum STEER_LIMIT = 32;

enum CallKind : string
{
    Start = "start",
    Print = "print",
    Resume = "resume",
    Compact = "compact",
    Remove = "remove"
}

enum CallStatus : string
{
    Running = "running",
    Stopping = "stopping",
    Succeeded = "succeeded",
    Failed = "failed",
    Stopped = "stopped",
    Interrupted = "interrupted"
}

struct CallResult
{
    bool cancelled;
    string error;
    string reply;
    JSONValue exitStatus = JSONValue(null);
}

class Call
{
private:
    struct State
    {
        CallStatus status = CallStatus.Running;
        string sessionId;
        string finishedAt;
        JSONValue exitStatus = JSONValue(null);
        string error;
        string reply;
    }

    const string directory;
    const string logDirectory;
    AcpClient _connection;
    Mutex mutex;
    Mutex joinMutex;
    Thread monitor;
    State _state;
    bool stopRequested;
    bool joined;
    MonoTime settled;
    MonoTime deadline;
    bool steerable;
    size_t steerDepth;
    string[] steering;
    Duration _timeout = 120.seconds;

    State snapshot()
    {
        synchronized (mutex)
            return _state;
    }

    JSONValue record(State state)
    {
        return JSONValue([
            "id": JSONValue(id),
            "kind": JSONValue(cast(string)kind),
            "workspace": JSONValue(workspace),
            "model": JSONValue(model),
            "createdAt": JSONValue(createdAt),
            "finishedAt": state.finishedAt.length ? JSONValue(state.finishedAt) : JSONValue(null),
            "status": JSONValue(cast(string)state.status),
            "sessionId": state.sessionId.length ? JSONValue(state.sessionId) : JSONValue(null),
            "exitStatus": state.exitStatus,
            "error": state.error.length ? JSONValue(state.error) : JSONValue(null),
            "reply": state.reply.length ? JSONValue(state.reply) : JSONValue(null),
            "profile": JSONValue(profileName),
            "mode": JSONValue(mode),
            "trusted": JSONValue(trusted)
        ]);
    }

    void appendLog()
    {
        if (!_state.sessionId.length || kind == CallKind.Remove)
            return;

        File log = openFile(buildPath(logDirectory, _state.sessionId~".log"), O_RDWR | O_CREAT | O_APPEND);
        scope(exit)
            log.close();

        if (exists(outputPath))
            log.write(readText(outputPath, 1024 * 1024));
        if (exists(errorPath))
            log.write(readText(errorPath, 1024 * 1024));

        log.flush();
    }

    void finish(CallResult result)
    {
        if (result.error.length)
        {
            File diagnostic = openFile(errorPath, O_RDWR | O_CREAT | O_APPEND);
            scope(exit) diagnostic.close();
            diagnostic.write(result.error~"\n");
        }
        synchronized (mutex)
        {
            settled = MonoTime.currTime;
            steerable = false;
            steering = null;
            _state.exitStatus = result.exitStatus;
            _state.reply = result.reply;
            _state.finishedAt = Clock.currTime(UTC()).toISOExtString();
            _state.error = result.error;
            _state.status = result.cancelled || stopRequested ? CallStatus.Stopped :
                result.error.length ? CallStatus.Failed : CallStatus.Succeeded;
        }
        appendLog();
    }

public:
    const string id;
    const CallKind kind;
    const string workspace;
    const string model;
    const string createdAt;
    string profileName;
    string mode;
    bool trusted;

    this(
        string directory,
        string logDirectory,
        string id,
        CallKind kind,
        string workspace,
        string model,
        string sessionId = null,
        string createdAt = null
    )
    {
        UUID(id);
        this.directory = directory.idup;
        this.logDirectory = logDirectory.idup;
        this.id = id.idup;
        mkdirRecurse(directory);
        mkdirRecurse(logDirectory);
        setAttributes(directory, octal!"700");
        setAttributes(logDirectory, octal!"700");
        this.kind = kind;
        this.workspace = workspace.idup;
        this.model = model.length ? model.idup : "";
        this.createdAt = createdAt.length ? createdAt.idup : Clock.currTime().toUTC().toISOExtString();
        mutex = new Mutex();
        joinMutex = new Mutex();
        _state.sessionId = sessionId.idup;
    }

    AcpClient connection()
    {
        synchronized (mutex)
            return _connection;
    }

    package(daemon.interop) void connection(AcpClient value)
    {
        synchronized (mutex)
            _connection = value;
    }

    package(daemon.interop) void identify(string session)
    {
        Session.validateId(session);
        synchronized (mutex)
        {
            if (_state.sessionId.length && _state.sessionId != session)
                throw new Exception("Call is already bound to another session");

            _state.sessionId = session.idup;
        }
    }

    package(daemon.interop) bool stopped()
    {
        synchronized (mutex)
            return stopRequested;
    }

    package(daemon.interop) Duration timeout()
        => _timeout;

    package(daemon.interop) void markSteerable(bool value = true)
    {
        synchronized (mutex)
            steerable = value;
    }

    package(daemon.interop) string[] takeSteering()
    {
        synchronized (mutex)
        {
            string[] ret = steering;
            steering = null;
            return ret;
        }
    }

    bool enqueueSteer(string prompt)
    {
        synchronized (mutex)
        {
            if (!steerable || stopRequested || _state.status != CallStatus.Running ||
                steerDepth >= STEER_LIMIT)
                return false;

            steerDepth++;
            steering ~= prompt.idup;
            return true;
        }
    }

    package(daemon.interop) void steerDone()
    {
        synchronized (mutex)
            if (steerDepth)
                steerDepth--;
    }

    package(daemon.interop) string[] closeSteering()
    {
        synchronized (mutex)
        {
            steerable = false;
            string[] ret = steering;
            steering = null;
            return ret;
        }
    }

    bool acceptingSteer()
    {
        synchronized (mutex)
            return steerable;
    }

    MonoTime expiresAt()
        => deadline;

    CallStatus status()
        => snapshot.status;

    string sessionId()
        => snapshot.sessionId;

    string finishedAt()
        => snapshot.finishedAt;

    JSONValue exitStatus()
        => snapshot.exitStatus;

    bool running()
        => status == CallStatus.Running || status == CallStatus.Stopping;

    string outputPath() const
        => buildPath(directory, id~".out");

    string errorPath() const
        => buildPath(directory, id~".err");

    void requestStop()
    {
        synchronized (mutex)
        {
            if (_state.status != CallStatus.Running && _state.status != CallStatus.Stopping)
                return;

            stopRequested = true;
            _state.status = CallStatus.Stopping;
        }
    }

    void wait()
    {
        synchronized (joinMutex)
        {
            if (monitor !is null && !joined)
            {
                monitor.join();
                joined = true;
            }
        }
    }

    void stop()
    {
        requestStop();
        wait();
    }

    JSONValue toJSON()
    {
        State state = snapshot;
        JSONValue ret = record(state);
        if (state.reply.length)
            ret["reply"] = JSONValue(state.reply);
        else if (state.status == CallStatus.Succeeded && kind == CallKind.Print &&
            exists(outputPath))
            ret["reply"] = JSONValue(readText(outputPath, 1024 * 1024));
        else
            ret["reply"] = JSONValue(null);

        return ret;
    }

}

class Bridge
{
private:
    struct Observed
    {
        string connection;
        string directory;
        bool active;
    }

    Session[string] sessions;
    Call[string] executions;
    bool[string] collected;
    bool[string] removed;
    Observed[string] observed;
    MonoTime[string] connections;

    void dropObserved(string id)
    {
        observed.remove(id);
        access.revokeMcp(id);
    }

    Call newCall(
        CallKind kind,
        string directory,
        string model,
        string sessionId = null
    )
    {
        return new Call(
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
            throw new ConflictException("Call capacity reached");
    }

    void launch(Call call, string prompt = null, bool compactFirst = false,
        Call previous = null, string connection = null)
    {
        checkCapacity();
        string runToken = access.begin(call);
        executions[call.id] = call;
        call._timeout = call.kind == CallKind.Remove ? 10.seconds : executionTimeout;
        call.deadline = MonoTime.currTime + call.timeout;
        call.monitor = new Thread({
            CallResult result;
            try
            {
                if (call.kind == CallKind.Remove)
                {
                    if (previous !is null)
                        previous.stop();
                    if (call.stopped)
                        result.cancelled = true;
                    else
                        result = removeProcess(call);
                }
                else if (connection.length)
                {
                    result = runControl(call, controlSocket(connection), access.clientToken,
                        call.sessionId, prompt, call.model, normalizeMode(call.mode));
                }
                else if (call.stopped)
                    result.cancelled = true;
                else
                {
                    result = runAcp(call, command, call.workspace, call.sessionId, prompt,
                        call.model, call.mode, runToken, mcpPort, dataDir, access, compactFirst);
                }
            }
            catch (Exception error)
                result.error = error.msg.idup;
            call.finish(result);
        });
        call.monitor.start();
    }

public:
    Access access;
    Duration executionTimeout = 30 * 60.seconds;
    const string command;
    const string logDir;
    const string executionDir;

    this(DaemonConfig configuration)
    {
        command = configuration.devinCommand;
        logDir = buildPath(configuration.dataDir, "sessions");
        sessionLockDir = configuration.sessionLockDir;
        sessionDatabase = configuration.sessionDatabase;
        dataDir = configuration.dataDir;
        mcpPort = environment.get("AUTONOM_PORT", "8080");
        executionTimeout = configuration.executionTimeout;
        controlMutex = new Mutex();
        access = new Access(dirName(logDir));
        executionDir = buildPath(dirName(logDir), "executions");
        if ((exists(logDir) && isSymlink(logDir)) ||
            (exists(executionDir) && isSymlink(executionDir)))
            throw new Exception("Backend storage must not be a symlink");

        collect();
    }

    Session session(string id)
    {
        Session.validateId(id);
        return resolve(id, sessionMetadata(id));
    }

    Session findSession(string id)
    {
        Session.validateId(id);
        if (id in removed)
            return null;

        SessionMetadata data = sessionMetadata(id);
        if (data.id.length || observedSession(id))
        {
            return resolve(id, data);
        }
        if (Session* found = id in sessions)
        {
            if ((*found).isRunning())
                return *found;
        }

        return null;
    }

    Session[] list(string directory = null, string acp = null)
    {
        Session[] ret;
        bool[string] listed;
        foreach (data; readSessionCatalog(sessionDatabase))
        {
            Session.validateId(data.id);
            if (data.id in removed)
                continue;

            Session entry = resolve(data.id, data);
            listed[entry.id] = true;
            if ((!directory.length || data.directory == directory) &&
                (!acp.length || data.acp == acp))
                ret ~= entry;
        }
        foreach (id, observedEntry; observed)
        {
            if (id !in sessions)
                sessions[id] = new Session(id, this);
        }
        foreach (id, entry; sessions)
        {
            if (id !in listed && id !in removed &&
                (entry.isRunning() || observedSession(id)))
            {
                entry.updateMetadata(SessionMetadata.init);
                if ((!directory.length || entry.workspace == directory) && !acp.length)
                    ret ~= entry;
            }
        }

        return ret;
    }

    Call execution(string id)
    {
        Session.validateId(id);
        Call* found = id in executions;
        return found is null ? null : *found;
    }

    JSONValue pendingPermissions(string id, long requestId = 0)
    {
        if (observedSession(id))
            return controlRequest(controlSocket(observedConnection(id)), access.clientToken,
                "autonom/permissions", JSONValue([
                    "sessionId": JSONValue(id), "id": JSONValue(requestId)
                ]), null, 250.msecs);
        foreach (execution; executions)
        {
            if (execution.running && execution.sessionId == id && execution.connection !is null)
                return execution.connection.permissions(id, requestId);
        }
        return JSONValue.emptyArray;
    }

    void decidePermission(string id, long requestId, string option)
    {
        try
        {
            if (observedSession(id))
            {
                controlRequest(controlSocket(observedConnection(id)), access.clientToken,
                    "autonom/permission", JSONValue([
                        "sessionId": JSONValue(id), "id": JSONValue(requestId),
                        "optionId": option.length ? JSONValue(option) : JSONValue(null)
                    ]), null, 250.msecs);
                return;
            }
            foreach (execution; executions)
            {
                if (execution.running && execution.sessionId == id && execution.connection !is null)
                {
                    execution.connection.decide(id, requestId, option);
                    return;
                }
            }
            throw new ConflictException("Permission request is no longer pending");
        }
        catch (AcpException error)
        {
            if (error.code == -32602)
                throw new InvalidInputException(error.msg);
            throw new ConflictException(error.msg);
        }
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
                    dropObserved(id);
            }
            return;
        }

        connections[connection.idup] = MonoTime.currTime;
        bool[string] listed;
        foreach (id; ids)
        {
            Session.validateId(id);
            observed[id.idup] = Observed(
                connection.idup,
                directories.get(id, null),
                active.get(id, false)
            );
            listed[id.idup] = true;
        }
        foreach (id; observed.keys)
        {
            if (observed[id].connection == connection && id !in listed)
                dropObserved(id);
        }
    }

    void admitObserved(string connection, string id, string directory)
    {
        Session.validateId(id);
        connections[connection.idup] = MonoTime.currTime;
        Observed* found = id in observed;
        observed[id.idup] = Observed(
            connection.idup,
            directory.length ? directory :
                found !is null && found.connection == connection ? found.directory : null,
            found !is null && found.connection == connection && found.active
        );
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
                dropObserved(id);
        }
    }

    Call[] listCalls(string directory = null)
    {
        Call[] ret;
        foreach (execution; executions)
        {
            if (!directory.length || execution.workspace == directory)
                ret ~= execution;
        }

        ret.sort!((left, right) => left.createdAt < right.createdAt);
        return ret;
    }

    Call authenticate(string token, string id, bool bind = false)
    {
        Call ret = access.authenticate(token, id, bind);
        if (ret !is null)
            session(id).bindCall(ret);

        return ret;
    }

    string[] collect()
    {
        sweepObserved();
        Call[] ready;
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
                if (execution.kind == CallKind.Remove && execution.status == CallStatus.Succeeded)
                {
                    removeLog(id);
                    sessions.remove(id);
                    access.forget(id);
                    removed[id] = true;
                }
                else if (id !in removed)
                {
                    if (execution.kind == CallKind.Start || execution.kind == CallKind.Print)
                        access.remember(id, execution.trusted);

                    Session session = this.session(id);
                    if (session.execution is null || session.execution.createdAt <= execution.createdAt)
                        session.bindCall(execution);
                }
            }

            collected[execution.id] = true;
        }

        foreach (id; executions.keys)
        {
            Call call = executions[id];
            if (!call.running && (MonoTime.currTime - call.settled > 300.seconds || executions.length > 128))
            {
                executions.remove(id);
                collected.remove(id);
            }
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

    const string sessionLockDir;
    const string sessionDatabase;
    const string dataDir;
    const string mcpPort;

    bool online(string id)
    {
        Session.validateId(id);
        string path = lockPath(id);
        if (!exists(path))
            return false;

        File file = openFile(path, O_RDONLY);
        scope(exit)
            file.close();

        int result = flock(file.fileno, LOCK_EX | LOCK_NB);
        if (result != 0 && errno != EWOULDBLOCK)
            throw new ErrnoException("Could not inspect session lock");

        return result != 0;
    }

    SessionMetadata sessionMetadata(string id)
    {
        Session.validateId(id);
        SessionMetadata ret = readSessionMetadata(sessionDatabase, id);

        if (!ret.id.length)
            ret.directory = observedDirectory(id);

        return ret;
    }

    Call remove(string id)
    {
        Session session = this.session(id);
        if (session.isRunning() && session.execution.kind == CallKind.Remove)
            return session.execution;
        if (observedSession(id) || (!session.isRunning() && online(id)))
            throw new ConflictException("Cannot remove a session owned by another process");

        Call ret = newCall(CallKind.Remove, null, null, session.id);
        launch(ret, null, false, session.execution);
        session.bindCall(ret);
        return ret;
    }

    Call resume(
        string id,
        string prompt,
        string directory,
        string model,
        bool compactFirst = false,
        string mode = null
    )
    {
        Call ret = submit(CallKind.Resume, prompt, directory, model, id, compactFirst, mode);
        session(id).bindCall(ret);
        return ret;
    }

    Call resumeObserved(
        string id,
        string prompt,
        string directory,
        string model,
        string mode
    )
    {
        if (!prompt.length || prompt.canFind('\0'))
            throw new InvalidInputException("A prompt is required");
        if (model.canFind('\0'))
            throw new InvalidInputException("Invalid model name");

        string connection = observedConnection(id);
        if (!connection.length)
            throw new ConflictException("Observed session is no longer connected");

        string observed = observedDirectory(id);
        if (directory.length && observed.length && directory != observed)
            throw new InvalidInputException("Directory does not match the observed session");
        if (!observed.length)
            throw new InvalidInputException("An existing working directory is required");
        directory = observed;

        Call ret = newCall(CallKind.Resume, directory, model, id);
        ret.mode = mode.idup;
        launch(ret, prompt, false, null, connection);
        session(id).bindCall(ret);
        return ret;
    }

    void cancelObserved(string id)
    {
        string connection = observedConnection(id);
        if (!connection.length)
            throw new ConflictException("Observed session is no longer connected");

        string socketPath = controlSocket(connection);
        string token = access.clientToken;
        synchronized (controlMutex)
        {
            if (id in cancelling || cancelling.length >= 8)
                return;

            cancelling[id] = true;
        }
        (new Thread({
            try
                controlRequest(socketPath, token, "session/cancel",
                    JSONValue(["sessionId": JSONValue(id)]));
            catch (Exception)
            {
            }
            synchronized (controlMutex)
                cancelling.remove(id);
        })).start();
    }

    Call steerObserved(string id, string prompt)
    {
        if (!prompt.length || prompt.canFind('\0'))
            throw new InvalidInputException("A prompt is required");

        string connection = observedConnection(id);
        if (!connection.length)
            throw new ConflictException("Observed session is no longer connected");

        Call ret = newCall(CallKind.Resume, observedDirectory(id), null, id);
        launch(ret, prompt, false, null, connection);
        session(id).bindCall(ret);
        return ret;
    }

    Call start(
        string prompt,
        string directory,
        string model = null,
        string mode = null,
        bool trusted = false,
        string profileName = null
    )
        => submit(CallKind.Start, prompt, directory, model, null, false, mode, trusted, profileName);

    Call print(string prompt, string directory, string model = null)
        => submit(CallKind.Print, prompt, directory, model);

    Call steer(string id, string prompt)
    {
        if (!prompt.length || prompt.canFind('\0'))
            throw new InvalidInputException("A prompt is required");

        Session bound = session(id);
        Call active = bound.execution;
        if (active !is null && active.running && active.acceptingSteer)
        {
            if (!active.enqueueSteer(prompt))
                throw new ConflictException("Steering capacity reached");

            return active;
        }
        if (observedSession(id))
            return steerObserved(id, prompt);

        throw new BackendException("Session does not support steering");
    }

private:
    Session resolve(string id, SessionMetadata data)
    {
        Session ret;
        if (Session* found = id in sessions)
            ret = *found;
        else
        {
            ret = new Session(id, this);
            sessions[ret.id] = ret;
        }
        ret.updateMetadata(data);
        return ret;
    }

    Mutex controlMutex;
    bool[string] cancelling;

    string lockPath(string id) const
        => buildPath(sessionLockDir, id~".lock");

    string controlSocket(string connection) const
        => buildPath(dataDir, "acp", connection~".sock");

    CallResult removeProcess(Call call)
    {
        File output = openFile(call.outputPath, O_RDWR | O_CREAT | O_APPEND);
        File errors = openFile(call.errorPath, O_RDWR | O_CREAT | O_APPEND);
        File input = File("/dev/null", "r");
        scope(exit)
        {
            output.close();
            errors.close();
            input.close();
        }
        Config options = Config.newEnv | Config.retainStdin | Config.retainStdout | Config.retainStderr;
        options.preExecFunction = &createProcessGroup;
        Pid process = spawnProcess([command, "rm", "--force", "--", call.sessionId],
            input, output, errors, childEnvironment(), options);
        bool reaped;
        scope(exit)
        {
            if (!reaped)
                terminate(process, 1.seconds);
        }
        typeof(tryWait(Pid.init)) result;
        while (!(result = tryWait(process)).terminated)
        {
            if (call.stopped || MonoTime.currTime >= call.deadline ||
                output.size > 1024 * 1024 || errors.size > 1024 * 1024)
            {
                result.status = terminate(process, 1.seconds);
                result.terminated = true;
                break;
            }
            Thread.sleep(10.msecs);
        }
        reaped = true;
        CallResult ret;
        ret.cancelled = call.stopped;
        ret.exitStatus = JSONValue(result.status);
        if (MonoTime.currTime >= call.deadline)
            ret.error = "Session removal timed out";
        else if (result.status != 0)
            ret.error = "Session removal failed (exit "~result.status.to!string~")";
        return ret;
    }

    Call submit(
        CallKind kind,
        string prompt,
        string directory,
        string model,
        string id = null,
        bool compactFirst = false,
        string mode = null,
        bool trusted = false,
        string profileName = null
    )
    {
        if (!prompt.length || prompt.canFind('\0'))
            throw new InvalidInputException("A prompt is required");
        if (model.canFind('\0'))
            throw new InvalidInputException("Invalid model name");
        if (!directory.length || !exists(directory) || !isDir(directory))
            throw new InvalidInputException("An existing working directory is required");

        normalizeMode(mode);
        if (id.length)
        {
            SessionMetadata metadata = sessionMetadata(id);
            if (!model.length)
                model = metadata.model;
            if (!mode.length)
                mode = metadata.mode;

            trusted = access.trusted(id);
        }

        Call ret = newCall(kind, directory, model, id);
        ret.mode = mode.idup;
        ret.trusted = trusted;
        ret.profileName = profileName.idup;
        launch(ret, prompt, compactFirst);
        return ret;
    }
}
