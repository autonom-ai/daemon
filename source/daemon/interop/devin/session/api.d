module daemon.interop.devin.session.api;

import daemon.agent : Profile, validName;
import daemon.exception : InvalidInputException, ConflictException;
import daemon.http;
import daemon.interop.call : Call;
import daemon.interop.devin.session : Session;
import daemon.interop.devin.session.control : remove;
import daemon.storage;
static import daemon.api;

import serverino;

import std.conv : to;
import std.json : JSONType, JSONValue;
import std.string : toLower;

private Session lookupSession(string pattern)(Request request, Output output)
{
    Session ret = daemon.api.bridge.findSession(routeParameter!pattern(request));
    if (ret is null)
        respondError(output, 404, "Session not found");

    return ret;
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
                (profile.session.hasActiveCall() || daemon.api.bridge.online(profile.session.id)))
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

@endpoint @route!"/api/print"
void printSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    Launch launch = readLaunch(request);
    respond(output, daemon.api.bridge.print(launch.prompt, launch.directory, launch.model).toJSON(), 202);
}
