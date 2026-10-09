module autonom.interop.session;

import autonom.server : profileStore, readBody, readLaunch, respond;
import autonom.storage : openFile;
import serverino : Output, Request, endpoint, route;

import core.sys.posix.fcntl : O_RDONLY;
import std.algorithm : findSplit, startsWith;
import std.array : join;
import std.ascii : isAlphaNum;
import std.exception : enforce;
import std.file : exists;
import std.json : JSONValue;
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

@endpoint @route!(sessionRoute!"resume")
void resumeSession(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    JSONValue data = readLaunch(request);
    Session session = request.requestSession;
    session.resume(data["prompt"].str, data["directory"].str, data["model"].str);
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
    string path = session.logPath;
    if (path.length == 0 || !exists(path))
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

/// Contract for a managed agent session.
abstract class Session
{
public:
    const string id;

    this(string id)
    {
        enforce(id.length && id.length <= 128 && isAlphaNum(id[0]), "Invalid session ID");
        foreach (character; id)
            enforce(isAlphaNum(character) || character == '-' || character == '_', "Invalid session ID");

        this.id = id.idup;
    }

    /// Gets the current session status.
    abstract SessionStatus status();

    /// Reports whether the process owned by this handle is running.
    abstract bool isRunning();

    /// Continues the session with a prompt, starting its process.
    abstract void resume(string prompt, string directory, string model = null);

    /// Stops the session process owned by this handle.
    abstract void stop();

    /// Removes the session and its artifacts.
    abstract void remove();

    /// Gets the exit status of the last session process, or null while unknown.
    abstract ref const(Nullable!int) exitStatus() const;

    /// Gets the path of the session log, or null when the session has no log.
    abstract string logPath();

    JSONValue toJSON()
    {
        return JSONValue([
            "id": JSONValue(id),
            "status": JSONValue(cast(string)status()),
            "exitStatus": exitStatus.isNull ? JSONValue(null) : JSONValue(exitStatus.get)
        ]);
    }
}
