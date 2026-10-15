module daemon.coord.access;

import daemon.agent;
import daemon.coord;
import daemon.events.event : EventType;
import daemon.exception;
import daemon.http;
import daemon.runtime;
import serverino;

import std.conv : to;
import std.json : JSONType, JSONValue;
import std.string : strip;

private:

enum DEFAULT_LIMIT = 50;
enum MAX_LIMIT = 500;
enum MAX_TEXT = 4000;

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

string[] names(JSONValue value, string message)
{
    if (value.type != JSONType.array)
        throw new InvalidInputException(message);

    string[] ret = new string[0];
    foreach (entry; value.array)
    {
        if (entry.type != JSONType.string)
            throw new InvalidInputException(message);

        ret ~= entry.str;
    }

    return ret;
}

string messageText(JSONValue data)
{
    if ("text" !in data.object || data["text"].type != JSONType.string)
        throw new InvalidInputException("A message needs text");

    string ret = data["text"].str;
    if (!ret.strip.length)
        throw new InvalidInputException("A message needs text");
    if (ret.length > MAX_TEXT)
        throw new InvalidInputException("Message text is too long");

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
        respondError(output, 404, "Profile not found");

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

Room lookup(string name, Profile profile, Output output, bool delegate(Room room) access)
{
    Room ret = bus.getRoom(name);
    if (ret is null || !access(ret))
    {
        respondError(output, 404, "Unknown room");
        return null;
    }

    return ret;
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
    if ("name" !in data.object || data["name"].type != JSONType.string)
        throw new InvalidInputException("A room name is required");

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
        Room found = lookup(name, profile, output, (room) => room.visible(profile.name));
        if (found is null)
            return;

        respond(output, bus.roomEntry(found, profile));
        return;
    }

    Room found = lookup(name, profile, output, (room) => room.administrator(profile.name));
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
    Room room = lookup(routeParameter!"/api/rooms/<name>/messages"(request), profile, output,
        (room) => room.visible(profile.name));
    if (room is null)
        return;

    if (request.method == Request.Method.Get)
    {
        Entry[] entries = bus.readRoom(room, profile, readLimit(request));
        events.clear(profile, EventType.Room, room.name);
        JSONValue ret = JSONValue.emptyObject;
        ret["source"] = JSONValue("room");
        ret["room"] = JSONValue(room.name);
        ret["messages"] = entryArray(entries);
        respond(output, ret);
        return;
    }

    JSONValue data = readBody(request);
    onlyFields(data, ["text", "ping"]);
    Profile[] targets;
    if (!profileList(pingNames(data), output, targets))
        return;

    Entry entry = bus.post(room, profile, messageText(data), targets);
    scheduler.posted(room, entry, profile, targets);
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
        Room found = lookup(name, profile, output, (room) => room.visible(profile.name));
        if (found is null)
            return;

        respond(output, found.toJSON());
        return;
    }

    Room room = lookup(name, profile, output, (room) => room.administrator(profile.name));
    if (room is null)
        return;

    JSONValue data = readBody(request);
    onlyFields(data, ["involved"]);
    if ("involved" !in data.object)
        throw new InvalidInputException("Expected the involved field");

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
    Room room = lookup(routeParameter!"/api/rooms/<name>/admins"(request), profile, output,
        (room) => room.originalOwner(profile.name));
    if (room is null)
        return;

    Profile target;
    if (request.method == Request.Method.Post)
    {
        JSONValue data = readBody(request);
        onlyFields(data, ["profile"]);
        if ("profile" !in data.object || data["profile"].type != JSONType.string)
            throw new InvalidInputException("A profile is required");

        target = profileByName(data["profile"].str, output);
    }
    else
    {
        string name = request.get.read("profile");
        if (!name.length)
            throw new InvalidInputException("A profile is required");

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
        if (source != "dms" && source != "pings")
            throw new InvalidInputException("Source must be dms or pings");

        size_t limit = readLimit(request);
        Entry[] entries;
        if (source == "dms")
        {
            entries = bus.readDirect(profile, limit);
            events.clear(profile, EventType.DM);
        }
        else
        {
            entries = bus.readPings(profile, limit);
            events.clear(profile, EventType.Ping);
        }

        JSONValue ret = JSONValue.emptyObject;
        ret["source"] = JSONValue(source);
        ret["messages"] = entryArray(entries);
        respond(output, ret);
        return;
    }

    JSONValue data = readBody(request);
    onlyFields(data, ["to", "text", "ping"]);
    if ("to" !in data.object || data["to"].type != JSONType.string)
        throw new InvalidInputException("A recipient is required");

    Profile to = profileByName(data["to"].str, output);
    if (to is null)
        return;

    Profile[] targets;
    if (!profileList(pingNames(data), output, targets))
        return;

    Entry entry = bus.direct(to, profile, messageText(data), targets);
    scheduler.directed(to, entry, profile, targets);
    respond(output, posted(entry, targets), 201);
}
