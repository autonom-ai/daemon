module daemon.interop.call;

import daemon.interop.acp : AcpClient;
import daemon.interop.session : Session;
import daemon.storage;

import core.sync.mutex : Mutex;
import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDWR;
import core.thread : Thread;
import core.time : Duration, MonoTime, seconds;
import std.conv : octal;
import std.datetime : Clock, UTC;
import std.file : exists, mkdirRecurse, setAttributes;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : File;
import std.uuid : UUID;

enum steerLimit = 32;

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
    Interrupted = "interrupted",
    Deferred = "deferred"
}

struct CallResult
{
    bool cancelled;
    bool interrupted;
    bool deferred;
    string stopReason;
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
        string stopReason;
    }

    const string directory;
    const string logDirectory;
    AcpClient _connection;
    Mutex mutex;
    Mutex joinMutex;
    package(daemon.interop) Thread monitor;
    State _state;
    bool stopRequested;
    bool joined;
    package(daemon.interop) MonoTime deadline;
    bool steerable;
    size_t steerDepth;
    string[] steering;
    package(daemon.interop) Duration _timeout = 120.seconds;

    package(daemon.interop) bool collected;

public:
    const string id;
    const CallKind kind;
    const string workspace;
    const string model;
    const string createdAt;
    string profileName;
    string mode;
    bool trusted;
    bool automatic;
    MonoTime settled;

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
                steerDepth >= steerLimit)
                return false;

            steerDepth++;
            steering ~= prompt.idup;
            return true;
        }
    }

    package(daemon.interop) void steerDone()
    {
        synchronized (mutex)
        {
            if (steerDepth)
                steerDepth--;
        }
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


private:
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
            "stopReason": state.stopReason.length ? JSONValue(state.stopReason) : JSONValue(null),
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

    package(daemon.interop) void finish(CallResult result)
    {
        if (result.error.length)
        {
            File diagnostic = openFile(errorPath, O_RDWR | O_CREAT | O_APPEND);
            scope(exit)
                diagnostic.close();
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
            _state.stopReason = result.stopReason;
            _state.status = result.cancelled || stopRequested
                ? CallStatus.Stopped
                : result.deferred ? CallStatus.Deferred
                : result.interrupted ? CallStatus.Interrupted
                : result.error.length ? CallStatus.Failed : CallStatus.Succeeded;
        }
        appendLog();
    }
}
