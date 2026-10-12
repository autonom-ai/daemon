module autonom.interop.permission;

import autonom.exception;
import autonom.server;
import serverino;

import std.datetime : Clock, UTC;
import std.json : JSONType, JSONValue, parseJSON;
import std.uuid : randomUUID;

public:

@endpoint @route!"/api/permissions"
void listPermissions(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    respond(output, permissions.pending());
}

@endpoint @route!(matchesPath!"/api/permissions/<id>")
void permission(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    Permission found = permissions.get(routeParameter!"/api/permissions/<id>"(request));
    if (found is null)
    {
        respond(output, JSONValue(["error": JSONValue("Permission request not found")]), 404);
        return;
    }

    bool human = bridge.access.client(request.header.read("x-autonom-client"));
    if (!human && (request.method != Request.Method.Get ||
        request.header.read("x-autonom-session") != found.session))
    {
        respond(output, JSONValue(["error": JSONValue("Permission request is not owned by this session")]), 403);
        return;
    }

    if (request.method == Request.Method.Post)
    {
        JSONValue data = readBody(request);
        if (data.object.length != 1 || "decision" !in data.object || data["decision"].type != JSONType.string)
            throw new InvalidInputException("A permission decision is required");

        found.decide(data["decision"].str);
    }

    respond(output, found.toJSON());
}

class PermissionStore
{
public:
    Permission add(string session, string tool, JSONValue input)
    {
        foreach (id; requests.keys)
        {
            if (requests[id].expired || requests[id].decision.length)
                requests.remove(id);
        }

        if (requests.length >= 64)
            throw new ConflictException("Too many pending permission requests");

        Permission ret = new Permission(session, tool, input);
        requests[ret.id] = ret;
        return ret;
    }

    Permission get(string id)
    {
        Permission* found = id in requests;
        return found is null ? null : *found;
    }

    JSONValue pending()
    {
        JSONValue ret = JSONValue.emptyArray;
        foreach (request; requests)
        {
            if (!request.decision.length && !request.expired)
                ret.array ~= request.toJSON();
        }

        return ret;
    }

private:
    Permission[string] requests;
}

class Permission
{
public:
    const string id;
    const string session;
    const string tool;
    const long createdAt;
    JSONValue input;
    string decision;

    this(string session, string tool, JSONValue input)
    {
        id = randomUUID().toString();
        this.session = session.idup;
        this.tool = tool.idup;
        this.input = parseJSON(input.toString());
        createdAt = Clock.currTime(UTC()).toUnixTime();
    }

    bool expired()
        => Clock.currTime(UTC()).toUnixTime() - createdAt >= 240;

    void decide(string value)
    {
        if (value != "approve" && value != "block")
            throw new InvalidInputException("Decision must be approve or block");
        if (decision.length || expired)
            throw new ConflictException("Permission request is no longer pending");

        decision = value.idup;
    }

    JSONValue toJSON()
    {
        return JSONValue([
            "id": JSONValue(id),
            "session": JSONValue(session),
            "tool": JSONValue(tool),
            "input": input,
            "createdAt": JSONValue(createdAt),
            "decision": JSONValue(expired ? "block" : decision),
            "reason": JSONValue(expired ? "Permission request expired" : "User permission decision")
        ]);
    }
}
