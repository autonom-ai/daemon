module daemon.interop.devin.session;

import daemon.agent : Profile, validName;
static import daemon.api;
import daemon.exception;
import daemon.http;
import daemon.interop.call;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.db : readSessionMessages;
import daemon.interop.metadata : SessionMetadata;
import daemon.interop.session : SessionBase = Session, SessionStatus;
import daemon.storage;

import serverino;

import std.algorithm : canFind;
import std.conv : to;
import std.file : exists;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.string : split, toLower;
import std.typecons : Nullable;

public:

class Session : SessionBase
{
private:
    Call _execution;
    Bridge bridge;
    SessionMetadata _metadata;

package(daemon.interop):
    void updateMetadata(SessionMetadata data)
    {
        _metadata = data;
    }

    void bindCall(Call execution)
    {
        _execution = execution;
    }

public:
    this(string id, Bridge bridge)
    {
        super(id);
        this.bridge = bridge;
    }

    override Call execution()
        => _execution;

    override bool isRunning()
        => _execution !is null && _execution.running;

    override void stop()
    {
        requestStop();
        if (_execution !is null)
            _execution.wait();
    }

    override Nullable!int exitStatus()
    {
        if (_execution is null || _execution.exitStatus.isNull)
            return Nullable!int.init;

        return Nullable!int(cast(int)_execution.exitStatus.integer);
    }

    override JSONValue toJSON(bool refresh = true)
    {
        if (refresh)
            _metadata = bridge.sessionMetadata(id);

        SessionMetadata data = metadata;

        JSONValue ret = data.toJSON();
        ret["id"] = JSONValue(id);
        ret["status"] = JSONValue(cast(string)status);
        ret["exitStatus"] = exitStatus.isNull ? JSONValue(null) : JSONValue(exitStatus.get);
        ret["executionId"] = _execution is null ? JSONValue(null) : JSONValue(_execution.id);
        return ret;
    }

    override SessionMetadata metadata()
    {
        SessionMetadata ret = _metadata;
        if (!ret.id.length)
        {
            if (_execution !is null)
            {
                ret.model = _execution.model;
                ret.mode = _execution.mode;
                ret.directory = _execution.workspace;
            }
            else
                ret.directory = bridge.observedDirectory(id);

            if (isRunning() || bridge.observedSession(id))
                ret.acp = "autonom";
        }

        return ret;
    }

    override SessionStatus status()
    {
        if (execution !is null && execution.status == CallStatus.Stopping)
            return SessionStatus.Stopping;

        if (isRunning())
            return bridge.online(id) ? SessionStatus.Online : SessionStatus.Starting;
        if (bridge.observedActive(id))
            return SessionStatus.Online;
        if (bridge.online(id))
            return SessionStatus.Loaded;

        if (execution !is null && (execution.status == CallStatus.Failed ||
            execution.status == CallStatus.Interrupted))
            return SessionStatus.Failed;

        return SessionStatus.Offline;
    }

    override void resume(
        string prompt,
        string directory,
        string model = null,
        string mode = null
    )
    {
        if (bridge.observedSession(id))
        {
            if (bridge.observedActive(id))
                throw new ConflictException("Session is already active");

            bridge.resumeObserved(id, prompt, directory, model, mode);
            return;
        }

        if (isRunning() || bridge.online(id))
            throw new ConflictException("Session is already active");

        bridge.resume(id, prompt, directory, model, false, mode);
    }

    override Call steer(string prompt)
        => bridge.steer(id, prompt);

    override void requestStop()
    {
        if (isRunning())
            execution.requestStop();
        else if (bridge.observedActive(id))
            bridge.cancelObserved(id);
        else if (bridge.online(id))
            throw new ConflictException("Cannot stop a session owned by another process");
    }

    override void remove()
    {
        bridge.remove(id).wait();
        bridge.collect();
    }

    override string logPath()
        => bridge.logPath(id);
}

@endpoint @route!"/api/sessions"
void sessions(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    if (request.method == Request.Method.Get)
    {
        JSONValue ret = JSONValue.emptyArray;
        foreach (session; daemon.api.bridge.list(request.get.read("directory"), request.get.read("acp")))
            ret.array ~= session.toJSON(false);

        respond(output, ret);
    }
    else
    {
        Launch launch = readLaunch(request);
        string profileName = launch.profile.toLower;
        if (profileName.length)
        {
            if (!validName(profileName) || profileName == "human")
                throw new InvalidInputException("Invalid profile name");

            Profile profile = daemon.api.profileStore.get(profileName);
            if (profile !is null && profile.session !is null &&
                (profile.session.isRunning() || daemon.api.bridge.online(profile.session.id)))
                throw new ConflictException("Profile is already active");
            foreach (execution; daemon.api.bridge.listCalls())
            {
                if (execution.running && execution.profileName == profileName)
                    throw new ConflictException("Profile already has a starting session");
            }
        }

        respond(output, daemon.api.bridge.start(
            launch.prompt,
            launch.directory,
            launch.model,
            launch.mode,
            launch.trusted,
            profileName
        ).toJSON(), 202);
    }
}

private:

Session lookupSession(string PATTERN)(Request request, Output output)
{
    Session ret = daemon.api.bridge.findSession(routeParameter!PATTERN(request));
    if (ret is null)
        respondError(output, 404, "Session not found");

    return ret;
}

public:

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
            Call execution = daemon.api.bridge.remove(id.str);
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
        respond(output, daemon.api.bridge.remove(routeParameter!"/api/sessions/<id>"(request)).toJSON(), 202);
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

    Launch launch = readLaunch(request);
    string id = routeParameter!"/api/sessions/<id>/resume"(request);
    if (!daemon.api.bridge.access.managed(id) && !daemon.api.bridge.observedSession(id))
        throw new ConflictException("Only sessions started or observed by Autonom may be resumed by Autonom");

    Session session = daemon.api.bridge.session(id);
    if (daemon.api.bridge.observedSession(id))
    {
        if (daemon.api.bridge.observedActive(id))
            throw new ConflictException("Session is already active");
    }
    else if (session.isRunning() || daemon.api.bridge.online(id))
        throw new ConflictException("Session is already active");

    session.resume(
        launch.prompt,
        launch.directory,
        launch.model,
        launch.mode
    );
    respond(output, session.toJSON());
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/steer")
void steerSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readBody(request);
    if (data.object.length != 1 || "prompt" !in data.object || data["prompt"].type != JSONType.string)
        throw new InvalidInputException("Expected only the prompt field");

    string id = routeParameter!"/api/sessions/<id>/steer"(request);
    if (!daemon.api.bridge.access.managed(id) && !daemon.api.bridge.observedSession(id))
        throw new ConflictException("Only sessions started or observed by Autonom may be steered");

    Session session = lookupSession!"/api/sessions/<id>/steer"(request, output);
    if (session is null)
        return;

    respond(output, session.steer(data["prompt"].str).toJSON(), 202);
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
        respondError(output, 404, "Session log not found");
    else
        respond(output, JSONValue(["log": JSONValue(readText(session.logPath, 1024 * 1024))]));
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/manage")
void manageSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    string id = routeParameter!"/api/sessions/<id>/manage"(request);
    Session.validateId(id);
    daemon.api.bridge.access.remember(id, false);
    respond(output, JSONValue(["id": JSONValue(id), "managed": JSONValue(true)]));
}


@endpoint @route!(matchesPath!"/api/sessions/<id>/permissions")
void sessionPermissions(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;
    string id = routeParameter!"/api/sessions/<id>/permissions"(request);
    Session.validateId(id);
    if (request.method == Request.Method.Post)
    {
        JSONValue data = readBody(request);
        onlyFields(data, ["id", "optionId"]);
        if ("id" !in data.object || data["id"].type != JSONType.integer ||
            "optionId" !in data.object || (!data["optionId"].isNull && data["optionId"].type != JSONType.string))
            throw new InvalidInputException("Expected an integer request id and an offered optionId, or null to cancel");
        daemon.api.bridge.decidePermission(id, data["id"].integer, data["optionId"].isNull ? null : data["optionId"].str);
        respond(output, JSONValue.emptyObject);
    }
    else
    {
        long requestId;
        if (request.get.has("id"))
        {
            try
                requestId = request.get.read("id").to!long;
            catch (Exception)
                throw new InvalidInputException("Permission request id must be an integer");
        }
        respond(output, daemon.api.bridge.pendingPermissions(id, requestId));
    }
}

bool matchSessionPermissionWithReqId(const Request request)
{
    string[] parts = request.path.split("/");
    return parts.length == 6 && parts[1] == "api" && parts[2] == "sessions" &&
           parts[4] == "permissions" && parts[3].length > 0 && parts[5].length > 0;
}

@endpoint @route!matchSessionPermissionWithReqId
void sessionPermissionById(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;
    string[] parts = request.path.split("/");
    string id = parts[3];
    Session.validateId(id);
    long requestId;
    try
        requestId = parts[5].to!long;
    catch (Exception)
        throw new InvalidInputException("Permission request id must be an integer");

    if (request.method == Request.Method.Post)
    {
        JSONValue data = readBody(request);
        if ("id" in data.object && data["id"].type == JSONType.integer && data["id"].integer != requestId)
            throw new InvalidInputException("Request id mismatch between path and body");
        onlyFields(data, ["id", "optionId"]);
        if ("optionId" !in data.object || (!data["optionId"].isNull && data["optionId"].type != JSONType.string))
            throw new InvalidInputException("Expected an offered optionId, or null to cancel");
        daemon.api.bridge.decidePermission(id, requestId, data["optionId"].isNull ? null : data["optionId"].str);
        respond(output, JSONValue.emptyObject);
    }
    else
    {
        respond(output, daemon.api.bridge.pendingPermissions(id, requestId));
    }
}

private void handleTranscript(string id, Output output)
{
    try
    {
        Call execution = daemon.api.bridge.execution(id);
        JSONValue executionJson = execution !is null ? execution.toJSON() : daemon.api.bridge.executionRecord(id);

        string session;
        if (execution !is null && execution.sessionId.length)
            session = execution.sessionId;
        else
        {
            string mapped = daemon.api.bridge.sessionForExecution(id);
            session = mapped.length ? mapped : id;
        }

        string executionOut = buildPath(daemon.api.bridge.executionDir, id ~ ".out");
        string executionErr = buildPath(daemon.api.bridge.executionDir, id ~ ".err");
        bool isKnownExecution = execution !is null || !executionJson.isNull ||
            exists(executionOut) || exists(executionErr);

        bool isKnownSession = session.length && (
            daemon.api.bridge.access.managed(session) ||
            daemon.api.bridge.findSession(session) !is null ||
            exists(daemon.api.bridge.logPath(session))
        );

        if (!isKnownExecution && !isKnownSession)
        {
            respondError(output, 404, "Session is not managed by Autonom");
            return;
        }

        JSONValue ret = JSONValue.emptyObject;
        ret["messages"] = JSONValue.emptyArray;
        ret["execution"] = executionJson.isNull ? JSONValue(null) : executionJson;

        if (session.length && isKnownSession)
        {
            Session found = daemon.api.bridge.findSession(session);
            if (execution is null && found !is null && found.execution !is null)
            {
                execution = found.execution;
                if (ret["execution"].isNull)
                    ret["execution"] = execution.toJSON();
            }

            ret["session"] = found is null ? JSONValue(["id": JSONValue(session)]) : found.toJSON();
            try
                ret["messages"] = readSessionMessages(daemon.api.bridge.sessionDatabase, session);
            catch (Exception)
                ret["messages"] = JSONValue.emptyArray;

            if (!ret["messages"].array.length && exists(daemon.api.bridge.logPath(session)))
            {
                try
                {
                    string sessionLog = readText(daemon.api.bridge.logPath(session), 1024 * 1024);
                    if (sessionLog.length)
                    {
                        ret["messages"].array ~= JSONValue([
                            "role": JSONValue("assistant"),
                            "content": JSONValue(sessionLog)
                        ]);
                    }
                }
                catch (Exception)
                {
                }
            }
        }
        else
            ret["session"] = JSONValue(null);

        if (!ret["messages"].array.length)
        {
            if (exists(executionOut))
            {
                try
                {
                    string outContent = readText(executionOut, 1024 * 1024);
                    if (outContent.length)
                    {
                        ret["messages"].array ~= JSONValue([
                            "role": JSONValue("assistant"),
                            "content": JSONValue(outContent)
                        ]);
                    }
                }
                catch (Exception)
                {
                }
            }
            else if (execution !is null && !execution.running && exists(execution.outputPath))
            {
                try
                {
                    string outContent = readText(execution.outputPath, 1024 * 1024);
                    if (outContent.length)
                    {
                        ret["messages"].array ~= JSONValue([
                            "role": JSONValue("assistant"),
                            "content": JSONValue(outContent)
                        ]);
                    }
                }
                catch (Exception)
                {
                }
            }
        }

        respond(output, ret);
    }
    catch (Exception error)
    {
        respondError(output, 500, error.msg);
    }
}

@endpoint @route!(matchesPath!"/api/executions/<id>/transcript")
void executionTranscript(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    handleTranscript(routeParameter!"/api/executions/<id>/transcript"(request), output);
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/transcript")
void sessionTranscript(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    handleTranscript(routeParameter!"/api/sessions/<id>/transcript"(request), output);
}
