module daemon.interop.execution;

// TODO: Execution records should eventually be replaced by the CLI session database (daemon.interop.devin.db).

import daemon.http;
import daemon.interop.process;
import daemon.interop.session;
import daemon.runtime;
import daemon.storage;
import serverino;

import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_EXCL, O_RDWR;
import core.sys.posix.signal : SIGKILL, SIGTERM;
import core.sync.mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : octal, to;
import std.datetime : Clock, UTC;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.process;
import std.stdio : File;
import std.uuid;

public:

@endpoint @route!(matchesPath!"/api/executions/<id>")
void getExecution(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    Execution execution = bridge.execution(routeParameter!"/api/executions/<id>"(request));
    if (execution is null)
        respondError(output, 404, "Execution not found");
    else
        respond(output, execution.toJSON());
}

@endpoint @route!(matchesPath!"/api/executions/<id>/stop")
void stopExecution(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    Execution execution = bridge.execution(routeParameter!"/api/executions/<id>/stop"(request));
    if (execution is null)
    {
        respondError(output, 404, "Execution not found");
        return;
    }

    execution.requestStop();
    respond(output, execution.toJSON(), 202);
}

enum ExecutionKind : string
{
    Start = "start",
    Print = "print",
    Resume = "resume",
    Compact = "compact",
    Remove = "remove",
    Acp = "acp"
}

enum ExecutionStatus : string
{
    Running = "running",
    Stopping = "stopping",
    Succeeded = "succeeded",
    Failed = "failed",
    Stopped = "stopped",
    Interrupted = "interrupted"
}

struct TaskResult
{
    bool cancelled;
    string error;
    string reply;
    JSONValue exitStatus = JSONValue(null);
}

alias ExecutionTask = TaskResult delegate(Execution execution);

enum STEER_LIMIT = 32;

class Execution
{
private:
    struct State
    {
        ExecutionStatus status = ExecutionStatus.Running;
        string sessionId;
        string finishedAt;
        JSONValue exitStatus = JSONValue(null);
        string error;
        string reply;
    }

    const string directory;
    const string logDirectory;
    Mutex mutex;
    Mutex joinMutex;
    Thread monitor;
    State _state;
    bool stopRequested;
    bool joined;
    bool steerable;
    size_t steerDepth;
    string[] steering;
    Duration _timeout = 120.seconds;

    State snapshot()
    {
        synchronized (mutex)
            return _state;
    }

    static ExecutionKind parseKind(string value)
    {
        switch (value)
        {
        case "start":
            return ExecutionKind.Start;
        case "print":
            return ExecutionKind.Print;
        case "resume":
            return ExecutionKind.Resume;
        case "compact":
            return ExecutionKind.Compact;
        case "remove":
            return ExecutionKind.Remove;
        case "acp":
            return ExecutionKind.Acp;
        default:
            throw new Exception("Invalid execution kind");
        }
    }

    static ExecutionStatus parseStatus(string value)
    {
        switch (value)
        {
        case "running":
            return ExecutionStatus.Running;
        case "stopping":
            return ExecutionStatus.Stopping;
        case "succeeded":
            return ExecutionStatus.Succeeded;
        case "failed":
            return ExecutionStatus.Failed;
        case "stopped":
            return ExecutionStatus.Stopped;
        case "interrupted":
            return ExecutionStatus.Interrupted;
        default:
            throw new Exception("Invalid execution status");
        }
    }

    JSONValue record(State state)
    {
        return JSONValue([
            "version": JSONValue(3),
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

    void save()
    {
        atomicWrite(buildPath(directory, id~".json"), record(_state).toString());
    }

    void appendLog()
    {
        if (!_state.sessionId.length || kind == ExecutionKind.Remove)
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

    void execute(ExecutionTask task, Execution prerequisite, Execution dependency)
    {
        try
        {
            if (prerequisite !is null)
                prerequisite.stop();
            if (dependency !is null)
                dependency.wait();

            synchronized (mutex)
            {
                if (stopRequested)
                {
                    _state.status = ExecutionStatus.Stopped;
                    _state.finishedAt = Clock.currTime(UTC()).toISOExtString();
                    save();
                    return;
                }
            }

            TaskResult result = task(this);
            synchronized (mutex)
            {
                steerable = false;
                steering = null;
                _state.exitStatus = result.exitStatus;
                _state.reply = result.reply;
                _state.finishedAt = Clock.currTime(UTC()).toISOExtString();
                if (result.cancelled || stopRequested)
                    _state.status = ExecutionStatus.Stopped;
                else if (result.error.length)
                {
                    _state.status = ExecutionStatus.Failed;
                    _state.error = result.error;
                }
                else
                    _state.status = ExecutionStatus.Succeeded;

                save();
            }

            appendLog();
        }
        catch (Exception error)
        {
            synchronized (mutex)
            {
                steerable = false;
                steering = null;
                _state.status = stopRequested ? ExecutionStatus.Stopped : ExecutionStatus.Failed;
                _state.finishedAt = Clock.currTime(UTC()).toISOExtString();
                _state.error = error.msg.idup;
                try
                    save();
                catch (Exception)
                {
                }
            }
        }
    }

public:
    const string id;
    const ExecutionKind kind;
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
        ExecutionKind kind,
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
        this.kind = kind;
        this.workspace = workspace.idup;
        this.model = model.length ? model.idup : "";
        this.createdAt = createdAt.length ? createdAt.idup : Clock.currTime().toUTC().toISOExtString();
        mutex = new Mutex();
        joinMutex = new Mutex();
        _state.sessionId = sessionId.idup;
    }

    package(daemon.interop) void identify(string session)
    {
        Session.validateId(session);
        synchronized (mutex)
        {
            if (_state.sessionId.length && _state.sessionId != session)
                throw new Exception("Execution is already bound to another session");

            _state.sessionId = session.idup;
            save();
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
            if (!steerable || stopRequested || _state.status != ExecutionStatus.Running ||
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

    ExecutionStatus status()
        => snapshot.status;

    string sessionId()
        => snapshot.sessionId;

    string finishedAt()
        => snapshot.finishedAt;

    JSONValue exitStatus()
        => snapshot.exitStatus;

    bool running()
        => status == ExecutionStatus.Running || status == ExecutionStatus.Stopping;

    string outputPath() const
        => buildPath(directory, id~".out");

    string errorPath() const
        => buildPath(directory, id~".err");

    void start(
        ExecutionTask task,
        Duration timeout = 120.seconds,
        Execution prerequisite = null,
        Execution dependency = null
    )
    {
        mkdirRecurse(directory);
        setAttributes(directory, octal!"700");
        mkdirRecurse(logDirectory);
        setAttributes(logDirectory, octal!"700");
        _timeout = timeout;
        save();
        monitor = new Thread({
            execute(task, prerequisite, dependency);
        });
        monitor.start();
    }

    void start(
        string[] arguments,
        string[string] environment,
        Duration timeout = 120.seconds,
        Execution prerequisite = null,
        Execution dependency = null
    )
    {
        string[] owned = arguments.dup;
        foreach (ref argument; owned)
            argument = argument.idup;

        start(processTask(owned, environment, workspace), timeout, prerequisite, dependency);
    }

    void requestStop()
    {
        synchronized (mutex)
        {
            if (_state.status != ExecutionStatus.Running && _state.status != ExecutionStatus.Stopping)
                return;

            stopRequested = true;
            _state.status = ExecutionStatus.Stopping;
            save();
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
        ret.object.remove("version");
        if (state.reply.length)
            ret["reply"] = JSONValue(state.reply);
        else if (state.status == ExecutionStatus.Succeeded && kind == ExecutionKind.Print &&
            exists(outputPath))
            ret["reply"] = JSONValue(readText(outputPath, 1024 * 1024));
        else
            ret["reply"] = JSONValue(null);

        return ret;
    }

    static Execution load(string directory, string logDirectory, string id)
    {
        JSONValue data = readJSON(buildPath(directory, id~".json"));
        if (data.type != JSONType.object || "version" !in data.object ||
            (data["version"] != JSONValue(1) && data["version"] != JSONValue(2) &&
            data["version"] != JSONValue(3)))
            throw new Exception("Invalid execution record");

        foreach (field; ["id", "kind", "workspace", "model", "createdAt", "status"])
        {
            if (field !in data.object || data[field].type != JSONType.string)
                throw new Exception("Invalid execution record");
        }

        if (data["id"].str != id || "sessionId" !in data.object || "exitStatus" !in data.object ||
            "error" !in data.object)
            throw new Exception("Invalid execution record");
        if (!data["sessionId"].isNull && data["sessionId"].type != JSONType.string)
            throw new Exception("Invalid execution session");
        if (!data["exitStatus"].isNull && data["exitStatus"].type != JSONType.integer)
            throw new Exception("Invalid execution exit");
        if (!data["error"].isNull && data["error"].type != JSONType.string)
            throw new Exception("Invalid execution error");
        if (data["version"] != JSONValue(1) &&
            ("finishedAt" !in data.object || (!data["finishedAt"].isNull && data["finishedAt"].type != JSONType.string)))
            throw new Exception("Invalid execution finish");
        if ("reply" in data.object && !data["reply"].isNull && data["reply"].type != JSONType.string)
            throw new Exception("Invalid execution reply");

        Execution ret = new Execution(
            directory,
            logDirectory,
            id,
            parseKind(data["kind"].str),
            data["workspace"].str,
            data["model"].str,
            data["sessionId"].isNull ? null : data["sessionId"].str,
            data["createdAt"].str
        );
        if (ret.sessionId.length)
            Session.validateId(ret.sessionId);

        if ("profile" in data.object && data["profile"].type == JSONType.string)
            ret.profileName = data["profile"].str.idup;
        if ("mode" in data.object && data["mode"].type == JSONType.string)
            ret.mode = data["mode"].str.idup;
        if ("trusted" in data.object &&
            (data["trusted"].type == JSONType.true_ || data["trusted"].type == JSONType.false_))
            ret.trusted = data["trusted"].boolean;
        if ("reply" in data.object && !data["reply"].isNull)
            ret._state.reply = data["reply"].str.idup;

        ret._state.status = parseStatus(data["status"].str);
        ret._state.exitStatus = data["exitStatus"];
        ret._state.error = data["error"].isNull ? null : data["error"].str;
        if ("finishedAt" in data.object && !data["finishedAt"].isNull)
            ret._state.finishedAt = data["finishedAt"].str.idup;

        if (ret.running)
        {
            ret._state.status = ExecutionStatus.Interrupted;
            ret._state.finishedAt = Clock.currTime(UTC()).toISOExtString();
            ret._state.error = "Daemon stopped before execution completed";
            ret.save();
        }

        return ret;
    }
}

package(daemon.interop):

ExecutionTask processTask(string[] arguments, string[string] environment, string workspace)
{
    return (Execution execution) {
        Pid process;
        bool timedOut;
        bool signalled;
        bool forced;
        typeof(tryWait(Pid.init)) result;
        try
        {
            File output = openFile(execution.outputPath, O_RDWR | O_CREAT | O_EXCL);
            File errors = openFile(execution.errorPath, O_RDWR | O_CREAT | O_EXCL);
            scope(exit)
            {
                output.close();
                errors.close();
            }

            File source = File("/dev/null", "r");
            scope(exit)
                source.close();

            Config options = Config.newEnv | Config.retainStdin | Config.retainStdout | Config.retainStderr;
            options.preExecFunction = &createProcessGroup;
            process = spawnProcess(
                arguments,
                source,
                output,
                errors,
                environment,
                options,
                workspace.length ? workspace : null
            );

            MonoTime deadline = MonoTime.currTime + execution.timeout;
            while (!(result = tryWait(process)).terminated)
            {
                bool stopping = execution.stopped;
                if (!signalled && (stopping || MonoTime.currTime >= deadline))
                {
                    timedOut = !stopping;
                    signal(process, SIGTERM);
                    signalled = true;
                    deadline = MonoTime.currTime + 5.seconds;
                }
                else if (signalled && !forced && MonoTime.currTime >= deadline)
                {
                    signal(process, SIGKILL);
                    forced = true;
                }

                Thread.sleep(10.msecs);
            }

            TaskResult ret;
            ret.exitStatus = JSONValue(result.status);
            ret.cancelled = execution.stopped;
            if (timedOut)
            {
                ret.cancelled = false;
                ret.error = "CLI command timed out";
            }
            else if (result.status != 0)
                ret.error = "CLI command failed (exit "~result.status.to!string~")";

            return ret;
        }
        catch (Exception error)
        {
            if (process !is null && !result.terminated)
            {
                signal(process, SIGKILL);
                result.status = std.process.wait(process);
                result.terminated = true;
            }

            throw error;
        }
    };
}
