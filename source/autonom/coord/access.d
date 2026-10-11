module autonom.coord.access;

import autonom.agent;
import autonom.coord;
import autonom.exception;
import autonom.server;
import serverino;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONType, JSONValue;
import std.string : strip;

private:

enum DEFAULT_LIMIT = 50;
enum MAX_LIMIT = 500;
enum MAX_TEXT = 4000;

Profile caller(Request request)
{
    string session = request.get.read("session");
    enforce!InvalidInputException(session.length, "A session is required");
    Profile ret = profileStore.profileFor(session);
    enforce!ConflictException(ret !is null, "No profile is registered for this session");
    return ret;
}

void onlyFields(JSONValue data, string[] fields)
{
    foreach (name; data.object.keys)
        enforce!InvalidInputException(fields.canFind(name), "Unexpected "~name~" field");
}

size_t readLimit(Request request)
{
    string value = request.get.read("limit");
    if (!value.length)
        return DEFAULT_LIMIT;

    size_t ret;
    try
        ret = value.to!size_t;
    catch (Exception)
        throw new InvalidInputException("Invalid limit");

    if (ret < 1)
        return 1;

    return ret > MAX_LIMIT ? MAX_LIMIT : ret;
}

string messageText(JSONValue data)
{
    enforce!InvalidInputException(
        "text" in data.object && data["text"].type == JSONType.string,
        "A message needs text"
    );
    string ret = data["text"].str;
    enforce!InvalidInputException(ret.strip.length, "A message needs text");
    enforce!InvalidInputException(ret.length <= MAX_TEXT, "Message text is too long");
    return ret;
}

string[] names(JSONValue value, string message)
{
    enforce!InvalidInputException(value.type == JSONType.array, message);
    string[] ret = new string[0];
    foreach (entry; value.array)
    {
        enforce!InvalidInputException(entry.type == JSONType.string, message);
        ret ~= entry.str;
    }

    return ret;
}

string[] pingNames(JSONValue data)
{
    if ("ping" !in data.object || data["ping"].isNull)
        return null;

    return names(data["ping"], "Ping must be a list of profile names");
}

JSONValue entryArray(Entry[] entries)
{
    JSONValue ret = JSONValue.emptyArray;
    foreach (entry; entries)
        ret.array ~= entry.toJSON();

    return ret;
}

JSONValue posted(Entry entry, Profile[] targets)
{
    JSONValue ret = entry.toJSON();
    ret["pinged"] = JSONValue.emptyArray;
    foreach (target; targets)
        ret["pinged"].array ~= JSONValue(target.name);

    return ret;
}

Profile profileByName(string name, Output output)
{
    Profile ret = profileStore.get(name);
    if (ret is null)
        respond(output, JSONValue(["error": JSONValue("Profile not found")]), 404);

    return ret;
}

bool profileList(string[] profileNames, Output output, out Profile[] targets)
{
    targets = new Profile[0];
    foreach (name; profileNames)
    {
        Profile found = profileByName(name, output);
        if (found is null)
            return false;

        targets ~= found;
    }

    return true;
}

Room lookupRoom(string name, Profile profile, Output output)
{
    Room ret = bus.getRoom(name);
    if (ret !is null && ret.visible(profile.name))
        return ret;

    respond(output, JSONValue(["error": JSONValue("Unknown room")]), 404);
    return null;
}

Room lookupAdministered(string name, Profile profile, Output output)
{
    Room ret = bus.getRoom(name);
    if (ret !is null && ret.administrator(profile.name))
        return ret;

    respond(output, JSONValue(["error": JSONValue("Unknown room")]), 404);
    return null;
}

Room lookupOwned(string name, Profile profile, Output output)
{
    Room ret = bus.getRoom(name);
    if (ret !is null && ret.originalOwner(profile.name))
        return ret;

    respond(output, JSONValue(["error": JSONValue("Unknown room")]), 404);
    return null;
}

public:

@endpoint @route!"/api/rooms"
void rooms(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    Profile profile = caller(request);
    if (request.method == Request.Method.Get)
    {
        JSONValue[] ret;
        foreach (room; bus.visibleRooms(profile.name))
            ret ~= bus.roomEntry(room, profile);

        respond(output, JSONValue(ret));
        return;
    }

    JSONValue data = readBody(request);
    onlyFields(data, ["name"]);
    enforce!InvalidInputException(
        "name" in data.object && data["name"].type == JSONType.string,
        "A room name is required"
    );
    respond(output, bus.roomEntry(bus.createRoom(data["name"].str, profile.name), profile), 201);
}

@endpoint @route!(matchesPath!"/api/rooms/<name>")
void room(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Delete]))
        return;

    Profile profile = caller(request);
    string name = routeParameter!"/api/rooms/<name>"(request);
    if (request.method == Request.Method.Get)
    {
        Room found = lookupRoom(name, profile, output);
        if (found is null)
            return;

        respond(output, bus.roomEntry(found, profile));
        return;
    }

    Room found = lookupAdministered(name, profile, output);
    if (found is null)
        return;

    bus.deleteRoom(found);
    respond(output, JSONValue(["name": JSONValue(found.name)]));
}

@endpoint @route!(matchesPath!"/api/rooms/<name>/messages")
void roomMessages(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    Profile profile = caller(request);
    Room room = lookupRoom(routeParameter!"/api/rooms/<name>/messages"(request), profile, output);
    if (room is null)
        return;

    if (request.method == Request.Method.Get)
    {
        JSONValue ret = JSONValue.emptyObject;
        ret["source"] = JSONValue("room");
        ret["room"] = JSONValue(room.name);
        ret["messages"] = entryArray(bus.readRoom(room, profile, readLimit(request)));
        respond(output, ret);
        return;
    }

    JSONValue data = readBody(request);
    onlyFields(data, ["text", "ping"]);
    Profile[] targets;
    if (!profileList(pingNames(data), output, targets))
        return;

    Entry entry = bus.post(room, profile, messageText(data), targets);
    respond(output, posted(entry, targets), 201);
}

@endpoint @route!(matchesPath!"/api/rooms/<name>/membership")
void roomMembership(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    Profile profile = caller(request);
    string name = routeParameter!"/api/rooms/<name>/membership"(request);
    if (request.method == Request.Method.Get)
    {
        Room found = lookupRoom(name, profile, output);
        if (found is null)
            return;

        respond(output, found.toJSON());
        return;
    }

    Room room = lookupAdministered(name, profile, output);
    if (room is null)
        return;

    JSONValue data = readBody(request);
    onlyFields(data, ["involved"]);
    enforce!InvalidInputException("involved" in data.object, "Expected the involved field");
    if (data["involved"].isNull)
        room.involveEveryone();
    else
    {
        Profile[] members;
        if (!profileList(names(data["involved"], "Involved must be a list of profiles or null"), output, members))
            return;

        string[] involved = new string[0];
        foreach (member; members)
            involved ~= member.name;

        room.setInvolved(involved);
    }

    respond(output, room.toJSON());
}

@endpoint @route!(matchesPath!"/api/rooms/<name>/admins")
void roomAdmins(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post, Request.Method.Delete]))
        return;

    Profile profile = caller(request);
    Room room = lookupOwned(routeParameter!"/api/rooms/<name>/admins"(request), profile, output);
    if (room is null)
        return;

    Profile target;
    if (request.method == Request.Method.Post)
    {
        JSONValue data = readBody(request);
        onlyFields(data, ["profile"]);
        enforce!InvalidInputException("profile" in data.object && data["profile"].type == JSONType.string,
            "A profile is required");
        target = profileByName(data["profile"].str, output);
    }
    else
    {
        string name = request.get.read("profile");
        enforce!InvalidInputException(name.length, "A profile is required");
        target = profileByName(name, output);
    }

    if (target is null)
        return;

    if (request.method == Request.Method.Post)
        room.addAdmin(target.name);
    else
        room.removeAdmin(target.name);

    respond(output, room.toJSON());
}

@endpoint @route!"/api/messages"
void messages(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    Profile profile = caller(request);
    if (request.method == Request.Method.Get)
    {
        string source = request.get.read("source");
        enforce!InvalidInputException(source == "dms" || source == "pings", "Source must be dms or pings");
        size_t limit = readLimit(request);
        JSONValue ret = JSONValue.emptyObject;
        ret["source"] = JSONValue(source);
        ret["messages"] = entryArray(source == "dms" ? bus.readDirect(profile, limit) : bus.readPings(profile, limit));
        respond(output, ret);
        return;
    }

    JSONValue data = readBody(request);
    onlyFields(data, ["to", "text", "ping"]);
    enforce!InvalidInputException("to" in data.object && data["to"].type == JSONType.string, "A recipient is required");
    Profile to = profileByName(data["to"].str, output);
    if (to is null)
        return;

    Profile[] targets;
    if (!profileList(pingNames(data), output, targets))
        return;

    Entry entry = bus.direct(to, profile, messageText(data), targets);
    respond(output, posted(entry, targets), 201);
}
