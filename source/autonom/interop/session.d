module autonom.interop.session;

import autonom.exception;
import autonom.interop.devin.db : SessionMetadata;
import autonom.interop.execution;
import autonom.server;
import autonom.storage;
import serverino;

import std.ascii;
import std.file;
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
    if (data.object.length != 1 || "ids" !in data.object)
        throw new InvalidInputException("Expected only the ids field");
    if (data["ids"].type != JSONType.array)
        throw new InvalidInputException("Session IDs must be an array");

    bool[string] seen;
    foreach (id; data["ids"].array)
    {
        if (id.type != JSONType.string)
            throw new InvalidInputException("Session IDs must be strings");
        if (id.str in seen)
            throw new InvalidInputException("Session IDs must be unique");

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
    string id = routeParameter!"/api/sessions/<id>/resume"(request);
    if (!bridge.access.managed(id))
        throw new ConflictException("Only sessions started by Autonom may be resumed by Autonom");

    Session session = bridge.session(id);
    if (session.isRunning() || bridge.online(id))
        throw new ConflictException("Session is already active");

    session.resume(
        data["prompt"].str,
        data["directory"].str,
        data["model"].str,
        data["mode"].str
    );
    respond(output, session.toJSON());
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/stop")
void stopSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    if (readBody(request).object.length != 0)
        throw new InvalidInputException("Expected an empty JSON object");
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
    Loaded = "loaded",
    Stopping = "stopping",
    Failed = "failed"
}

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
        if (!id.length || id.length > 128 || !isAlphaNum(id[0]))
            throw new InvalidInputException("Invalid session ID");

        foreach (character; id)
        {
            if (!isAlphaNum(character) && character != '-' && character != '_')
                throw new InvalidInputException("Invalid session ID");
        }
    }

    this(string id)
    {
        validateId(id);
        this.id = id.idup;
    }

    Execution execution()
        => _execution;

    abstract SessionStatus status();

    abstract SessionMetadata metadata();

    string model()
        => metadata.model;

    string title()
        => metadata.title;

    string mode()
        => metadata.mode;

    string workspace()
        => metadata.directory;

    bool isRunning()
        => _execution !is null && _execution.running;

    abstract void resume(
        string prompt,
        string directory,
        string model = null,
        string mode = null
    );

    abstract void requestStop();

    void stop()
    {
        requestStop();
        if (_execution !is null)
            _execution.wait();
    }

    abstract void remove();

    Nullable!int exitStatus()
    {
        if (_execution is null || _execution.exitStatus.isNull)
            return Nullable!int.init;

        return Nullable!int(cast(int)_execution.exitStatus.integer);
    }

    abstract string logPath();

    JSONValue toJSON()
    {
        SessionMetadata data = metadata;
        if (!data.id.length && _execution !is null)
        {
            data.model = _execution.model;
            data.mode = _execution.mode;
            data.directory = _execution.workspace;
        }

        JSONValue ret = data.toJSON();
        ret["id"] = JSONValue(id);
        ret["status"] = JSONValue(cast(string)status);
        ret["exitStatus"] = exitStatus.isNull ? JSONValue(null) : JSONValue(exitStatus.get);
        ret["executionId"] = _execution is null ? JSONValue(null) : JSONValue(_execution.id);
        return ret;
    }
}
