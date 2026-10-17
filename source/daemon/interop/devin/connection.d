module daemon.interop.devin.connection;

import daemon.exception : InvalidInputException, ConflictException;
import daemon.http;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.session : Session;
static import daemon.api;

import serverino;

import core.time : MonoTime, seconds;
import std.algorithm : canFind;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.uuid : UUID;

void dropObserved(Bridge owner, string id)
{
    owner.observed.remove(id);
    owner.access.revokeMcp(id);
}

bool observedSession(Bridge owner, string id)
    => (id in owner.observed) !is null;

bool observedActive(Bridge owner, string id)
{
    Bridge.Observed* found = id in owner.observed;
    return found !is null && found.active;
}

string observedConnection(Bridge owner, string id)
{
    Bridge.Observed* found = id in owner.observed;
    return found is null ? null : found.connection;
}

string observedDirectory(Bridge owner, string id)
{
    Bridge.Observed* found = id in owner.observed;
    return found is null ? null : found.directory;
}

void observeConnection(Bridge owner, string connection, string[] ids, string[string] directories,
    bool[string] active, bool closed)
{
    try
        UUID(connection);
    catch (Exception)
        throw new InvalidInputException("Invalid connection ID");

    if (closed)
    {
        owner.connections.remove(connection);
        foreach (id; owner.observed.keys)
        {
            if (owner.observed[id].connection == connection)
                owner.dropObserved(id);
        }
        return;
    }

    owner.connections[connection.idup] = MonoTime.currTime;
    bool[string] listed;
    foreach (id; ids)
    {
        Session.validateId(id);
        owner.observed[id.idup] = Bridge.Observed(
            connection.idup,
            directories.get(id, null),
            active.get(id, false)
        );
        listed[id.idup] = true;
    }
    foreach (id; owner.observed.keys)
    {
        if (owner.observed[id].connection == connection && id !in listed)
            owner.dropObserved(id);
    }
}

void admitObserved(Bridge owner, string connection, string id, string directory)
{
    Session.validateId(id);
    owner.connections[connection.idup] = MonoTime.currTime;
    Bridge.Observed* found = id in owner.observed;
    owner.observed[id.idup] = Bridge.Observed(
        connection.idup,
        directory.length
            ? directory
            : found !is null && found.connection == connection ? found.directory : null,
        found !is null && found.connection == connection && found.active
    );
}

void sweepObserved(Bridge owner)
{
    MonoTime cutoff = MonoTime.currTime - 30.seconds;
    foreach (connection; owner.connections.keys)
    {
        if (owner.connections[connection] < cutoff)
            owner.connections.remove(connection);
    }

    foreach (id; owner.observed.keys)
    {
        if (owner.observed[id].connection !in owner.connections)
            owner.dropObserved(id);
    }
}

string controlSocket(const Bridge owner, string connection)
    => buildPath(owner.dataDir, "acp", connection~".sock");

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
            throw new InvalidInputException("Bridge.Observed sessions require id, directory, and active");

        Session.validateId(entry["id"].str);
        if (entry["directory"].str.canFind('\0'))
            throw new InvalidInputException("Invalid observed directory");

        ids ~= entry["id"].str.idup;
        directories[entry["id"].str.idup] = entry["directory"].str.idup;
        active[entry["id"].str.idup] = entry["active"].boolean;
    }

    daemon.api.bridge.observeConnection(data["connection"].str, ids, directories, active, data["closed"].boolean);
    respond(output, JSONValue(["ok": JSONValue(true)]));
}

@endpoint @route!"/api/acp/admit"
void admit(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readBody(request);
    onlyFields(data, ["connection", "session", "token", "directory"]);
    foreach (required; ["connection", "session", "token"])
    {
        if (required !in data.object || data[required].type != JSONType.string)
            throw new InvalidInputException("Expected string connection, session, and token");
    }
    try
        UUID(data["connection"].str);
    catch (Exception)
        throw new InvalidInputException("Invalid connection ID");
    if (data["token"].str.length != 64)
        throw new InvalidInputException("Invalid MCP credential");
    foreach (character; data["token"].str)
    {
        if (!(character >= '0' && character <= '9') && !(character >= 'a' && character <= 'f'))
            throw new InvalidInputException("Invalid MCP credential");
    }
    if ("directory" in data.object &&
        (data["directory"].type != JSONType.string || data["directory"].str.canFind('\0')))
        throw new InvalidInputException("Invalid directory");

    daemon.api.bridge.admitObserved(data["connection"].str, data["session"].str,
        "directory" in data.object ? data["directory"].str : null);
    if (!daemon.api.bridge.access.admitMcp(data["token"].str, data["session"].str))
        throw new ConflictException("MCP credential is already bound to another session");

    daemon.api.bridge.access.remember(data["session"].str);

    respond(output, JSONValue(["session": data["session"]]));
}
