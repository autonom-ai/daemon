module autonom.interop.execution;

import autonom.interop.session : Session;
import autonom.server : acceptMethod, bridge, matchesPath, respond, routeParameter;
import autonom.storage : atomicWrite, openFile, readJSON, readText;
import serverino : Output, Request, endpoint, route;

import core.stdc.errno : errno, ESRCH;
import core.sync.mutex : Mutex;
import core.sys.linux.sys.prctl : prctl, PR_SET_PDEATHSIG;
import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_EXCL, O_RDWR;
import core.sys.posix.signal : kill, SIGKILL, SIGTERM;
import core.sys.posix.unistd : setpgid;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : octal, to;
import std.datetime : Clock;
import std.exception : enforce, errnoEnforce;
import std.file : mkdirRecurse, setAttributes;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.process : PROCESS_CONFIG = Config, Pid, spawnProcess, tryWait, reap = wait;
import std.stdio : File;
import std.uuid : UUID;

public:

/// Reads a persisted CLI execution or returns 404 when its ID is unknown.
@endpoint @route!(matchesPath!"/api/executions/<id>")
void getExecution(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    Execution execution = bridge.execution(routeParameter!"/api/executions/<id>"(request));
    if (execution is null)
        respond(output, JSONValue(["error": JSONValue("Execution not found")]), 404);
    else
        respond(output, execution.toJSON());
}

/// Requests that a running execution stop, returning its updated snapshot.
@endpoint @route!(matchesPath!"/api/executions/<id>/stop")
void stopExecution(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    Execution execution = bridge.execution(routeParameter!"/api/executions/<id>/stop"(request));
    if (execution is null)
    {
        respond(output, JSONValue(["error": JSONValue("Execution not found")]), 404);
        return;
    }

    execution.requestStop();
    respond(output, execution.toJSON(), 202);
}

/// Backend operation represented by a durable execution.
enum ExecutionKind : string
{
    Start = "start",
    Print = "print",
    Resume = "resume",
    Remove = "remove"
}

/// Persisted lifecycle states exposed by an execution handle.
enum ExecutionStatus : string
{
    Running = "running",
    Stopping = "stopping",
    Succeeded = "succeeded",
    Failed = "failed",
    Stopped = "stopped",
    Interrupted = "interrupted"
}

/// A durable record and process monitor for one CLI operation.
class Execution
{
private:
    struct State
    {
        ExecutionStatus status = ExecutionStatus.Running;
        string sessionId;
        JSONValue exitStatus = JSONValue(null);
        string error;
    }

    const string directory;
    const string logDirectory;
    Mutex mutex;
    Mutex joinMutex;
    Thread monitor;
    State _state;
    bool stopRequested;
    bool joined;

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
        case "remove":
            return ExecutionKind.Remove;
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
            "version": JSONValue(1),
            "id": JSONValue(id),
            "kind": JSONValue(cast(string)kind),
            "workspace": JSONValue(workspace),
            "model": JSONValue(model),
            "createdAt": JSONValue(createdAt),
            "status": JSONValue(cast(string)state.status),
            "sessionId": state.sessionId.length ? JSONValue(state.sessionId) : JSONValue(null),
            "exitStatus": state.exitStatus,
            "error": state.error.length ? JSONValue(state.error) : JSONValue(null)
        ]);
    }

    void save()
    {
        atomicWrite(buildPath(directory, id~".json"), record(_state).toString());
    }

    void finish(int exitStatus, bool timedOut)
    {
        synchronized (mutex)
        {
            _state.exitStatus = JSONValue(exitStatus);
            _state.status = stopRequested ? ExecutionStatus.Stopped :
                exitStatus == 0 && !timedOut ? ExecutionStatus.Succeeded : ExecutionStatus.Failed;
            if (timedOut)
                _state.error = "CLI command timed out";
            else if (_state.status == ExecutionStatus.Failed)
                _state.error = "CLI command failed (exit "~exitStatus.to!string~")";

            if (_state.status == ExecutionStatus.Succeeded &&
                (kind == ExecutionKind.Start || kind == ExecutionKind.Print))
            {
                JSONValue data = readJSON(exportPath, 16 * 1024 * 1024);
                enforce(data.type == JSONType.object && "session_id" in data.object &&
                    data["session_id"].type == JSONType.string, "CLI did not export a session ID");
                Session.validateId(data["session_id"].str);
                _state.sessionId = data["session_id"].str.idup;
            }

            if (_state.sessionId.length && kind != ExecutionKind.Remove)
            {
                File log = openFile(buildPath(logDirectory, _state.sessionId~".log"), O_RDWR | O_CREAT | O_APPEND);
                scope(exit)
                    log.close();

                log.write(readText(outputPath, 1024 * 1024));
                log.write(readText(errorPath, 1024 * 1024));
                log.flush();
            }

            save();
        }
    }

    void execute(
        string[] arguments,
        string[string] environment,
        Duration timeout,
        Execution prerequisite
    )
    {
        Pid process;
        bool timedOut;
        bool signalled;
        bool forced;
        typeof(tryWait(Pid.init)) result;
        try
        {
            if (prerequisite !is null)
                prerequisite.stop();

            File output = openFile(outputPath, O_RDWR | O_CREAT | O_EXCL);
            File errors = openFile(errorPath, O_RDWR | O_CREAT | O_EXCL);
            File exported = openFile(exportPath, O_RDWR | O_CREAT | O_EXCL);
            scope(exit)
            {
                output.close();
                errors.close();
                exported.close();
            }

            synchronized (mutex)
            {
                if (stopRequested)
                {
                    _state.status = ExecutionStatus.Stopped;
                    save();
                    return;
                }
            }

            PROCESS_CONFIG options = PROCESS_CONFIG.newEnv;
            options.preExecFunction = &createProcessGroup;
            process = spawnProcess(
                arguments,
                File("/dev/null", "r"),
                output,
                errors,
                environment,
                options,
                workspace.length ? workspace : null
            );
            MonoTime deadline = MonoTime.currTime + timeout;
            while (!(result = tryWait(process)).terminated)
            {
                bool stopping;
                synchronized (mutex)
                    stopping = stopRequested;

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

            finish(result.status, timedOut);
        }
        catch (Exception)
        {
            if (process !is null && !result.terminated)
            {
                signal(process, SIGKILL);
                result.status = reap(process);
                result.terminated = true;
            }

            synchronized (mutex)
            {
                _state.status = ExecutionStatus.Failed;
                _state.exitStatus = result.terminated ? JSONValue(result.status) : JSONValue(null);
                _state.error = "Could not complete execution or validate its session export";
                try
                    save();
                catch (Exception)
                {
                }
            }
        }
    }

public:
    /// Stable ID for the execution resource and its persisted record.
    const string id;
    /// Operation executed by the backend.
    const ExecutionKind kind;
    /// Working directory supplied to the CLI, or null for removal.
    const string workspace;
    /// Requested model, or null when the backend default is used.
    const string model;
    /// UTC creation timestamp used to order recovered executions.
    const string createdAt;

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
        this.model = model.idup;
        this.createdAt = createdAt.length ? createdAt.idup : Clock.currTime().toUTC().toISOExtString();
        mutex = new Mutex();
        joinMutex = new Mutex();
        _state.sessionId = sessionId.idup;
    }

    ExecutionStatus status()
        => snapshot.status;

    string sessionId()
        => snapshot.sessionId;

    JSONValue exitStatus()
        => snapshot.exitStatus;

    bool running()
        => status == ExecutionStatus.Running || status == ExecutionStatus.Stopping;

    string exportPath() const
        => buildPath(directory, id~".export");

    string outputPath() const
        => buildPath(directory, id~".out");

    string errorPath() const
        => buildPath(directory, id~".err");

    package(autonom.interop) static bool createProcessGroup() nothrow @nogc @trusted
        => setpgid(0, 0) == 0 && prctl(
            PR_SET_PDEATHSIG,
            SIGTERM,
            0,
            0,
            0
        ) == 0;

    package(autonom.interop) static void signal(Pid process, int signal)
    {
        if (process !is null && process.processID > 0)
            errnoEnforce(kill(-process.processID, signal) == 0 || errno == ESRCH, "Could not signal execution");
    }

    void start(
        string[] arguments,
        string[string] environment,
        Duration timeout = 120.seconds,
        Execution prerequisite = null
    )
    {
        mkdirRecurse(directory);
        setAttributes(directory, octal!"700");
        mkdirRecurse(logDirectory);
        setAttributes(logDirectory, octal!"700");
        string[] owned = arguments.dup;
        foreach (ref argument; owned)
            argument = argument.idup;

        save();
        monitor = new Thread({
            execute(owned, environment, timeout, prerequisite);
        });
        monitor.start();
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

    /// Returns the API snapshot, including the completed reply for print operations.
    JSONValue toJSON()
    {
        State state = snapshot;
        JSONValue ret = record(state);
        ret.object.remove("version");
        ret["reply"] = state.status == ExecutionStatus.Succeeded && kind == ExecutionKind.Print ?
            JSONValue(readText(outputPath, 1024 * 1024)) : JSONValue(null);
        return ret;
    }

    static Execution load(string directory, string logDirectory, string id)
    {
        JSONValue data = readJSON(buildPath(directory, id~".json"));
        enforce(data.type == JSONType.object && "version" in data.object && data["version"] == JSONValue(1),
            "Invalid execution record");
        foreach (field; ["id", "kind", "workspace", "model", "createdAt", "status"])
            enforce(field in data.object && data[field].type == JSONType.string, "Invalid execution record");

        enforce(data["id"].str == id && "sessionId" in data.object && "exitStatus" in data.object &&
            "error" in data.object, "Invalid execution record");
        enforce(data["sessionId"].isNull || data["sessionId"].type == JSONType.string, "Invalid execution session");
        enforce(data["exitStatus"].isNull || data["exitStatus"].type == JSONType.integer, "Invalid execution exit");
        enforce(data["error"].isNull || data["error"].type == JSONType.string, "Invalid execution error");
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

        ret._state.status = parseStatus(data["status"].str);
        ret._state.exitStatus = data["exitStatus"];
        ret._state.error = data["error"].isNull ? null : data["error"].str;
        if (ret.running)
        {
            ret._state.status = ExecutionStatus.Interrupted;
            ret._state.error = "Daemon stopped before execution completed";
            ret.save();
        }

        return ret;
    }
}
