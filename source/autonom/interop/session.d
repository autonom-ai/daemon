module autonom.interop.session;

import autonom.exception : InvalidInput;
import autonom.interop.execution : Execution;
import autonom.server : acceptMethod, bridge, matchesPath, readBody, readLaunch, respond, routeParameter;
import autonom.storage : readText;
import serverino : Output, Request, endpoint, priority, route;

import std.ascii : isAlphaNum;
import std.exception : enforce;
import std.file : exists;
import std.json : JSONType, JSONValue;
import std.typecons : Nullable;

private Session lookupSession(string PATTERN)(Request request, Output output)
{
    Session ret = bridge.findSession(routeParameter!PATTERN(request));
    if (ret is null)
        respond(output, JSONValue(["error": JSONValue("Session not found")]), 404);

    return ret;
}

@priority(10) @endpoint @route!"/api/sessions/remove"
void removeSessions(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readBody(request);
    enforce!InvalidInput(data.object.length == 1 && "ids" in data.object, "Expected only the ids field");
    enforce!InvalidInput(data["ids"].type == JSONType.array, "Session IDs must be an array");
    bool[string] seen;
    foreach (id; data["ids"].array)
    {
        enforce!InvalidInput(id.type == JSONType.string, "Session IDs must be strings");
        enforce!InvalidInput(id.str !in seen, "Session IDs must be unique");
        Session.validateId(id.str);
        seen[id.str.idup] = true;
    }

    JSONValue ret = JSONValue.emptyObject;
    ret["ids"] = data["ids"];
    ret["executions"] = JSONValue.emptyArray;
    ret["failed"] = JSONValue.emptyArray;
    bool pending;
    foreach (id; data["ids"].array)
    {
        try
        {
            Execution execution = bridge.remove(id.str);
            ret["executions"].array ~= JSONValue(["id": JSONValue(execution.id), "sessionId": id]);
            pending = pending || execution.running;
        }
        catch (Exception)
            ret["failed"].array ~= id;
    }

    respond(output, ret, pending ? 202 : ret["failed"].array.length ? 503 : 200);
}

@endpoint @route!(matchesPath!"/api/sessions/<id>")
void getSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Delete]))
        return;

    if (request.method == Request.Method.Delete)
        respond(output, bridge.remove(routeParameter!"/api/sessions/<id>"(request)).toJSON(), 202);
    else
    {
        Session session = lookupSession!"/api/sessions/<id>"(request, output);
        if (session !is null)
            respond(output, session.toJSON());
    }
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/resume")
void resumeSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readLaunch(request);
    Session session = bridge.session(routeParameter!"/api/sessions/<id>/resume"(request));
    session.resume(data["prompt"].str, data["directory"].str, data["model"].str);
    respond(output, session.toJSON());
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/stop")
void stopSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    enforce!InvalidInput(readBody(request).object.length == 0, "Expected an empty JSON object");
    Session session = lookupSession!"/api/sessions/<id>/stop"(request, output);
    if (session is null)
        return;

    session.requestStop();
    respond(output, session.toJSON(), 202);
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/log")
void sessionLog(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    Session session = lookupSession!"/api/sessions/<id>/log"(request, output);
    if (session is null)
        return;

    if (!exists(session.logPath))
        respond(output, JSONValue(["error": JSONValue("Session log not found")]), 404);
    else
        respond(output, JSONValue(["log": JSONValue(readText(session.logPath, 1024 * 1024))]));
}

enum SessionStatus : string
{
    Offline = "offline",
    Starting = "starting",
    Online = "online",
    Stopping = "stopping",
    Failed = "failed"
}

/// Contract for a managed agent session.
abstract class Session
{
private:
    Execution _execution;

package(autonom.interop):
    void bindExecution(Execution execution)
    {
        _execution = execution;
    }

public:
    const string id;

    static void validateId(string id)
    {
        enforce!InvalidInput(id.length && id.length <= 128 && isAlphaNum(id[0]), "Invalid session ID");
        foreach (character; id)
            enforce!InvalidInput(isAlphaNum(character) || character == '-' || character == '_', "Invalid session ID");
    }

    this(string id)
    {
        validateId(id);
        this.id = id.idup;
    }

    Execution execution()
        => _execution;

    /// Gets the current session status.
    abstract SessionStatus status();

    /// Reports whether the execution owned by this handle is running, without polling its process.
    bool isRunning()
        => _execution !is null && _execution.running;

    /// Continues the session with a prompt, starting its process.
    abstract void resume(string prompt, string directory, string model = null);

    abstract void requestStop();

    /// Stops the session process owned by this handle.
    void stop()
    {
        requestStop();
        if (_execution !is null)
            _execution.wait();
    }

    /// Removes the session and its artifacts.
    abstract void remove();

    /// Gets the exit status of the last session process, or null while unknown.
    Nullable!int exitStatus()
    {
        if (_execution is null || _execution.exitStatus.isNull)
            return Nullable!int.init;

        return Nullable!int(cast(int)_execution.exitStatus.integer);
    }

    /// Gets the path of the session log, or null when the session has no log.
    abstract string logPath();

    JSONValue toJSON()
    {
        return JSONValue([
            "id": JSONValue(id),
            "status": JSONValue(cast(string)status),
            "exitStatus": exitStatus.isNull ? JSONValue(null) : JSONValue(exitStatus.get),
            "executionId": _execution is null ? JSONValue(null) : JSONValue(_execution.id)
        ]);
    }
}
