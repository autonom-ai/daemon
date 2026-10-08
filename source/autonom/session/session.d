module autonom.session.session;

import autonom.server : profileStore, readBody, readLaunch, respond;
import autonom.session.bridge : Bridge;
import autonom.storage : openFile;
import serverino : Output, Request, endpoint, route;

import core.stdc.errno : errno, ESRCH;
import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDONLY, O_RDWR;
import core.sys.posix.signal : kill, SIGTERM;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm : findSplit, startsWith;
import std.array : join;
import std.ascii : isAlphaNum;
import std.exception : enforce, errnoEnforce;
import std.file : exists, isDir, isSymlink, mkdirRecurse, removeFile = remove;
import std.json : JSONValue;
import std.path : buildPath;
import std.process : Pid, tryWait;
import std.stdio : File;
import std.typecons : Nullable;

private:

bool sessionRoute(string ACTION)(const Request request)
{
    enum PREFIX = "/api/sessions/";
    if (!request.path.startsWith(PREFIX))
        return false;

    typeof(findSplit("", "/")) segments = request.path[PREFIX.length..$].findSplit("/");
    static if (ACTION.length)
        return segments[1].length && segments[2] == ACTION;
    else
        return !segments[1].length;
}

auto ref requestSession(Request request)
    => profileStore.sessionFor(request.path["/api/sessions/".length..$].findSplit("/")[0]);

public:

@endpoint @route!(sessionRoute!"")
void getSession(Request request, Output output)
{
    if (request.method == Request.Method.Get)
        respond(output, request.requestSession.toJSON());
    else if (request.method == Request.Method.Delete)
    {
        profileStore.removeSession(request.requestSession.id);
        respond(output, JSONValue(["removed": JSONValue(true)]));
    }
    else
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
}

@endpoint @route!(sessionRoute!"start")
void startSession(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    JSONValue data = readLaunch(request);
    Session session = request.requestSession;
    session.start(data["prompt"].str, data["directory"].str, data["model"].str);
    respond(output, session.toJSON());
}

@endpoint @route!(sessionRoute!"stop")
void stopSession(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    enforce(readBody(request).object.length == 0, "Expected an empty JSON object");
    Session session = request.requestSession;
    session.stop();
    respond(output, session.toJSON());
}

@endpoint @route!(sessionRoute!"log")
void sessionLog(Request request, Output output)
{
    if (request.method != Request.Method.Get)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    Session session = request.requestSession;
    string path = buildPath(session.bridge.logDir, session.id~".log");
    if (!exists(path))
    {
        respond(output, JSONValue(["error": JSONValue("Session log not found")]), 404);
        return;
    }

    File file = openFile(path, O_RDONLY);
    scope(exit)
        file.close();

    respond(output, JSONValue(["log": JSONValue(cast(string)file.byChunk(4096).join)]));
}

enum SessionStatus : string
{
    Offline = "offline",
    Starting = "starting",
    Online = "online",
    Failed = "failed"
}

abstract class Session
{
private:
    Pid process;
    Nullable!int _exitStatus;
    bool stopped;

protected:
    abstract string[] resumeArguments(string prompt, string model);

public:
    const string id;
    Bridge bridge;

    this(string id, Bridge bridge)
    {
        enforce(id.length && id.length <= 128 && isAlphaNum(id[0]), "Invalid session ID");
        foreach (character; id)
            enforce(isAlphaNum(character) || character == '-' || character == '_', "Invalid session ID");

        this.id = id;
        this.bridge = bridge;
    }

    ref const(Nullable!int) exitStatus() const
        => _exitStatus;

    abstract bool isOnline();

    bool isRunning()
    {
        if (process is null)
            return false;

        typeof(tryWait(Pid.init)) result = tryWait(process);
        if (!result.terminated)
            return true;

        _exitStatus = result.status;
        process = null;
        return false;
    }

    SessionStatus inspect()
    {
        bool running = isRunning();
        if (isOnline())
            return SessionStatus.Online;
        if (running)
            return SessionStatus.Starting;
        if (!stopped && !_exitStatus.isNull && _exitStatus.get != 0)
            return SessionStatus.Failed;

        return SessionStatus.Offline;
    }

    void start(string prompt, string directory, string model = null)
    {
        string[] arguments = resumeArguments(prompt, model);
        enforce(directory.length && isDir(directory), "An existing working directory is required");
        enforce(!isRunning() && !isOnline(), "Session is already active");
        enforce(!(exists(bridge.logDir) && isSymlink(bridge.logDir)), "Session log directory must not be a symlink");
        mkdirRecurse(bridge.logDir);
        process = bridge.spawn(
            arguments,
            directory,
            openFile(buildPath(bridge.logDir, id~".log"), O_RDWR | O_CREAT | O_APPEND)
        );
        _exitStatus.nullify();
        stopped = false;
    }

    void stop()
    {
        if (!isRunning())
        {
            enforce(!isOnline(), "Cannot stop a session owned by another process");
            return;
        }

        errnoEnforce(kill(-process.processID, SIGTERM) == 0 || errno == ESRCH, "Could not stop session");
        stopped = true;
        MonoTime deadline = MonoTime.currTime + 5.seconds;
        while (isRunning())
        {
            enforce(MonoTime.currTime < deadline, "Session did not stop within the timeout");
            Thread.sleep(10.msecs);
        }
    }

    void remove()
    {
        stop();
        bridge.remove(id);
        string log = buildPath(bridge.logDir, id~".log");
        if (exists(log))
            removeFile(log);
    }

    JSONValue toJSON()
    {
        return JSONValue([
            "id": JSONValue(id),
            "status": JSONValue(cast(string)inspect()),
            "exitStatus": _exitStatus.isNull ? JSONValue(null) : JSONValue(_exitStatus.get)
        ]);
    }
}
