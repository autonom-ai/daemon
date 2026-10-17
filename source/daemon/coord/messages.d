module daemon.coord.messages;

import daemon.agent;
import daemon.api;
import daemon.coord.api;
import daemon.coord;
import daemon.events.delivery : posted, directed;
import daemon.events.event : EventType;
import daemon.exception;
import daemon.http;

import serverino;

import std.json : JSONType, JSONValue;

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
    respond(output, messageResult(entry, targets), 201);
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
    respond(output, messageResult(entry, targets), 201);
}
