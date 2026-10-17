module daemon.interop.api;

import daemon.agent : Profile, validName;
import daemon.exception;
import daemon.http;
import daemon.interop.bridge;
import daemon.interop.bridge;
import daemon.interop.session;
import daemon.runtime : bridge, profileStore;
import daemon.storage;
import serverino;

import std.algorithm : canFind;
import std.conv : to;
import std.file : exists;
import std.json : JSONType, JSONValue;
import std.string : toLower;
import std.uuid : UUID;

public:

@endpoint @route!"/api/sessions"
void sessions(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    if (request.method == Request.Method.Get)
    {
        JSONValue ret = JSONValue.emptyArray;
        foreach (session; bridge.list(request.get.read("directory"), request.get.read("acp")))
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

            Profile profile = profileStore.get(profileName);
            if (profile !is null && profile.session !is null &&
                (profile.session.isRunning() || bridge.online(profile.session.id)))
                throw new ConflictException("Profile is already active");
            foreach (execution; bridge.listCalls())
            {
                if (execution.running && execution.profileName == profileName)
                    throw new ConflictException("Profile already has a starting session");
            }
        }

        respond(output, bridge.start(
            launch.prompt,
            launch.directory,
            launch.model,
            launch.mode,
            launch.trusted,
            profileName
        ).toJSON(), 202);
    }
}

@endpoint @route!"/api/print"
void printSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    Launch launch = readLaunch(request);
    respond(output, bridge.print(launch.prompt, launch.directory, launch.model).toJSON(), 202);
}

@endpoint @route!"/api/acp/observe"
void observe(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readBody(request, 1024 * 1024);
    string[string] required = [
        "connection": "string",
        "sessions": "array",
        "closed": "boolean"
    ];
    foreach (name, value; data.object)
    {
        if (name !in required)
            throw new InvalidInputException("Invalid observation field");
    }
    foreach (name, type; required)
    {
        if (name !in data.object)
            throw new InvalidInputException("Missing observation field "~name);
        if ((type == "string" && data[name].type != JSONType.string) ||
            (type == "array" && data[name].type != JSONType.array) ||
            (type == "boolean" && data[name].type != JSONType.true_ &&
            data[name].type != JSONType.false_))
            throw new InvalidInputException("Invalid observation field "~name);
    }

    try
        UUID(data["connection"].str);
    catch (Exception)
        throw new InvalidInputException("Invalid connection ID");

    string[] ids;
    string[string] directories;
    bool[string] active;
    foreach (entry; data["sessions"].array)
    {
        if (entry.type != JSONType.object)
            throw new InvalidInputException("Invalid observed session");
        foreach (name, value; entry.object)
        {
            if (name != "id" && name != "directory" && name != "active")
                throw new InvalidInputException("Invalid observed session field");
            if ((name == "id" || name == "directory") && value.type != JSONType.string)
                throw new InvalidInputException("Invalid observed session field");
            if (name == "active" && value.type != JSONType.true_ && value.type != JSONType.false_)
                throw new InvalidInputException("Invalid observed session field");
        }
        if ("id" !in entry.object || "directory" !in entry.object || "active" !in entry.object)
            throw new InvalidInputException("Observed sessions require id, directory, and active");

        Session.validateId(entry["id"].str);
        if (entry["directory"].str.canFind('\0'))
            throw new InvalidInputException("Invalid observed directory");

        ids ~= entry["id"].str.idup;
        directories[entry["id"].str.idup] = entry["directory"].str.idup;
        active[entry["id"].str.idup] = entry["active"].boolean;
    }

    bridge.observeConnection(data["connection"].str, ids, directories, active, data["closed"].boolean);
    respond(output, JSONValue(["ok": JSONValue(true)]));
}

private:

Session lookupSession(string PATTERN)(Request request, Output output)
{
    Session ret = bridge.findSession(routeParameter!PATTERN(request));
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
            Call execution = bridge.remove(id.str);
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

    Launch launch = readLaunch(request);
    string id = routeParameter!"/api/sessions/<id>/resume"(request);
    if (!bridge.access.managed(id) && !bridge.observedSession(id))
        throw new ConflictException("Only sessions started or observed by Autonom may be resumed by Autonom");

    Session session = bridge.session(id);
    if (bridge.observedSession(id))
    {
        if (bridge.observedActive(id))
            throw new ConflictException("Session is already active");
    }
    else if (session.isRunning() || bridge.online(id))
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
    if (!bridge.access.managed(id) && !bridge.observedSession(id))
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
    bridge.access.remember(id, false);
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
        bridge.decidePermission(id, data["id"].integer, data["optionId"].isNull ? null : data["optionId"].str);
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
        respond(output, bridge.pendingPermissions(id, requestId));
    }
}

@endpoint @route!(matchesPath!"/api/executions/<id>")
void getCall(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    Call execution = bridge.execution(routeParameter!"/api/executions/<id>"(request));
    if (execution is null)
        respondError(output, 404, "Call not found");
    else
        respond(output, execution.toJSON());
}

@endpoint @route!(matchesPath!"/api/executions/<id>/stop")
void stopCall(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    Call execution = bridge.execution(routeParameter!"/api/executions/<id>/stop"(request));
    if (execution is null)
    {
        respondError(output, 404, "Call not found");
        return;
    }

    execution.requestStop();
    respond(output, execution.toJSON(), 202);
}

