module daemon.coord.rooms;

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
