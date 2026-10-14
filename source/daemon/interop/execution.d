module daemon.interop.execution;

// TODO: Execution records should eventually be replaced by the CLI session database (daemon.interop.devin.db).

import daemon.interop.session;
import daemon.server;
import daemon.storage;
import serverino;

import core.stdc.errno : errno, ESRCH, EAGAIN, EINTR;
import core.sync.mutex;
import core.sys.linux.sys.prctl : prctl, PR_SET_PDEATHSIG;
import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_APPEND, O_CREAT, O_EXCL, O_NONBLOCK, O_RDWR;
import core.sys.posix.signal : kill, SIGKILL, SIGTERM;
import core.sys.posix.unistd : setpgid, writeInput = write;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : octal, to;
import std.datetime : Clock, UTC;
import std.exception : ErrnoException;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.process;
import std.stdio : File;
import std.string : startsWith;
import std.uuid;

public:

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

public:

string[string] childEnvironment()
    => Execution.childEnvironment();

void signalExecution(Pid process, int signal)
{
    Execution.signal(process, signal);
}

enum SCRUB_PREFIXES = [
    "ACP_",
    "ELECTRON_",
    "OPENROUTER_API_KEY",
    "VSCODE_",
    "WINDSURF_",
    "AUTONOM_RUN_",
    "AUTONOM_CLIENT_"
];

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
    }

    const string directory;
    const string logDirectory;
    Mutex mutex;
    Mutex joinMutex;
    Thread monitor;
    State _state;
    bool stopRequested;
    bool joined;
    string pendingInput;
    MonoTime lastRead;

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
            "version": JSONValue(2),
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
            "profile": JSONValue(profileName),
            "mode": JSONValue(mode),
            "trusted": JSONValue(trusted)
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
            _state.finishedAt = Clock.currTime(UTC()).toISOExtString();
            if (timedOut)
                _state.error = "CLI command timed out";
            else if (_state.status == ExecutionStatus.Failed)
                _state.error = "CLI command failed (exit "~exitStatus.to!string~")";

            if (_state.status == ExecutionStatus.Succeeded &&
                (kind == ExecutionKind.Start || kind == ExecutionKind.Print))
            {
                JSONValue data = readJSON(exportPath, 16 * 1024 * 1024);
                if (data.type != JSONType.object || "session_id" !in data.object ||
                    data["session_id"].type != JSONType.string)
                    throw new Exception("CLI did not export a session ID");
                Session.validateId(data["session_id"].str);
                if (_state.sessionId.length && _state.sessionId != data["session_id"].str)
                    throw new Exception("CLI exported a different session ID");

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
        Execution prerequisite,
        Execution dependency
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
            if (dependency !is null)
                dependency.wait();

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
                    _state.finishedAt = Clock.currTime(UTC()).toISOExtString();
                    save();
                    return;
                }
            }

            Pipe input;
            File source = File("/dev/null", "r");
            if (kind == ExecutionKind.Acp)
            {
                input = pipe();
                source = input.readEnd;
                int descriptor = input.writeEnd.fileno;
                if (fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == -1)
                    throw new ErrnoException("Could not configure ACP input");
            }

            scope(exit)
            {
                source.close();
                if (input.writeEnd.isOpen)
                    input.writeEnd.close();
            }

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
            if (kind == ExecutionKind.Acp)
                source.close();

            string buffered;
            MonoTime deadline = MonoTime.currTime + timeout;
            while (!(result = tryWait(process)).terminated)
            {
                if (kind == ExecutionKind.Acp)
                {
                    if (output.size > 32 * 1024 * 1024 || errors.size > 1024 * 1024)
                        throw new Exception("ACP output exceeded its size limit");
                    if (!buffered.length)
                    {
                        synchronized (mutex)
                        {
                            buffered = pendingInput;
                            pendingInput = null;
                        }
                    }

                    if (buffered.length)
                    {
                        ptrdiff_t written = writeInput(
                            input.writeEnd.fileno,
                            buffered.ptr,
                            buffered.length
                        );
                        if (written > 0)
                            buffered = buffered[written..$];
                        else if (written < 0 && errno != EAGAIN && errno != EINTR)
                            throw new ErrnoException("Could not write ACP input");
                    }
                }

                bool stopping;
                synchronized (mutex)
                {
                    stopping = stopRequested;
                    if (kind == ExecutionKind.Acp && MonoTime.currTime > lastRead + 15.seconds)
                        deadline = MonoTime.currTime;
                }

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
                result.status = std.process.wait(process);
                result.terminated = true;
            }

            synchronized (mutex)
            {
                _state.status = ExecutionStatus.Failed;
                _state.exitStatus = result.terminated ? JSONValue(result.status) : JSONValue(null);
                _state.finishedAt = Clock.currTime(UTC()).toISOExtString();
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

    string exportPath() const
        => buildPath(directory, id~".export");

    string outputPath() const
        => buildPath(directory, id~".out");

    string errorPath() const
        => buildPath(directory, id~".err");

    package(daemon.interop) static string[string] childEnvironment() nothrow
    {
        string[string] ret;
        try
        {
            ret = environment.toAA();
            foreach (name; ret.keys)
            {
                foreach (prefix; SCRUB_PREFIXES)
                {
                    if (name.startsWith(prefix))
                    {
                        ret.remove(name);
                        break;
                    }
                }
            }
        }
        catch (Exception)
        {
        }

        return ret;
    }

    package(daemon.interop) static bool createProcessGroup() nothrow @nogc @trusted
    {
        return setpgid(0, 0) == 0 && prctl(
            PR_SET_PDEATHSIG,
            SIGTERM,
            0,
            0,
            0
        ) == 0;
    }

    package(daemon.interop) static void signal(Pid process, int signal)
    {
        if (process !is null && process.processID > 0)
        {
            if (kill(-process.processID, signal) != 0 && errno != ESRCH)
                throw new ErrnoException("Could not signal execution");
        }
    }

    void start(
        string[] arguments,
        string[string] environment,
        Duration timeout = 120.seconds,
        Execution prerequisite = null,
        Execution dependency = null
    )
    {
        mkdirRecurse(directory);
        setAttributes(directory, octal!"700");
        mkdirRecurse(logDirectory);
        setAttributes(logDirectory, octal!"700");
        string[] owned = arguments.dup;
        foreach (ref argument; owned)
            argument = argument.idup;

        lastRead = MonoTime.currTime;
        save();
        monitor = new Thread({
            execute(owned, environment, timeout, prerequisite, dependency);
        });
        monitor.start();
    }

    void renewAcp()
    {
        synchronized (mutex)
            lastRead = MonoTime.currTime;
    }

    void sendFrame(string frame)
    {
        synchronized (mutex)
        {
            if (kind != ExecutionKind.Acp || _state.status != ExecutionStatus.Running)
                throw new Exception("ACP execution is not running");
            if (frame.length > 16 * 1024 * 1024 || pendingInput.length + frame.length > 16 * 1024 * 1024)
                throw new Exception("ACP input exceeded its size limit");

            pendingInput ~= frame.idup~"\n";
        }
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
        ret["reply"] = state.status == ExecutionStatus.Succeeded && kind == ExecutionKind.Print ?
            JSONValue(readText(outputPath, 1024 * 1024)) : JSONValue(null);
        return ret;
    }

    static Execution load(string directory, string logDirectory, string id)
    {
        JSONValue data = readJSON(buildPath(directory, id~".json"));
        if (data.type != JSONType.object || "version" !in data.object ||
            (data["version"] != JSONValue(1) && data["version"] != JSONValue(2)))
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
        if (data["version"] == JSONValue(2) &&
            ("finishedAt" !in data.object || (!data["finishedAt"].isNull && data["finishedAt"].type != JSONType.string)))
            throw new Exception("Invalid execution finish");

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

        ret._state.status = parseStatus(data["status"].str);
        ret._state.exitStatus = data["exitStatus"];
        ret._state.error = data["error"].isNull ? null : data["error"].str;
        if (data["version"] == JSONValue(2) && !data["finishedAt"].isNull)
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
