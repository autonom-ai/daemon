module daemon.events.api;

import daemon.agent;
import daemon.api;
import daemon.coord.stream : stdTimeTicksPerMillisecond;
import daemon.coord;
import daemon.events.event : EventType, parseEventType;
import daemon.events.schedule : Schedule, maxEvery;
import daemon.exception;
import daemon.http;

import serverino;

import core.time : seconds;
import std.conv : to;
import std.datetime : Clock, SysTime, UTC;
import std.file;
import std.json : JSONType, JSONValue;
import std.typecons : Nullable;

@endpoint @route!"/api/events"
void readEvents(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    Profile profile = caller(request);
    JSONValue ret = JSONValue.emptyObject;
    ret["events"] = JSONValue.emptyArray;
    foreach (event; events.read(profile))
        ret["events"].array ~= event.toJSON();

    respond(output, ret);
}

@endpoint @route!"/api/schedules"
void schedules(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    Profile profile = caller(request);
    if (request.method == Request.Method.Get)
    {
        JSONValue[] ret;
        foreach (schedule; scheduleStore.list(profile))
            ret ~= schedule.toJSON();

        respond(output, JSONValue(ret));
        return;
    }

    Nullable!Schedule schedule = readSchedule(profile, readBody(request), output);
    if (schedule.isNull)
        return;

    if (scheduler !is null)
        scheduler.publishNextDue();
    respond(output, schedule.get.toJSON(), 201);
}

@endpoint @route!(matchesPath!"/api/schedules/<id>")
void schedule(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Delete]))
        return;

    Profile profile = caller(request);
    Nullable!Schedule removed = scheduleStore.remove(profile, routeParameter!"/api/schedules/<id>"(request));
    if (removed.isNull)
        respondError(output, 404, "Schedule not found");
    else
    {
        if (scheduler !is null)
            scheduler.publishNextDue();

        respond(output, removed.get.toJSON());
    }
}

@priority(10) @endpoint @route!"/api/schedules/refresh"
void refreshSchedules(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    if (readBody(request).object.length != 0)
        throw new InvalidInputException("Expected an empty JSON object");

    respond(output, JSONValue(cast(JSONValue[string])null));
}

Nullable!Schedule readSchedule(Profile profile, JSONValue data, Output output)
{
    onlyFields(data, ["type", "from", "room", "at", "every"]);
    if ("type" !in data.object || data["type"].type != JSONType.string)
        throw new InvalidInputException("A schedule needs a type");

    EventType type;
    if (!parseEventType(data["type"].str, type))
        throw new InvalidInputException("Unknown schedule type");

    string from;
    if ("from" in data.object && !data["from"].isNull)
    {
        if (data["from"].type != JSONType.string)
            throw new InvalidInputException("from must be a profile name");

        Profile sender = profileStore.get(data["from"].str);
        if (sender is null)
            throw new InvalidInputException("Unknown profile");

        from = sender.name;
    }

    string room;
    if (type == EventType.Room)
    {
        if ("room" !in data.object || data["room"].type != JSONType.string)
            throw new InvalidInputException("A room schedule needs a room");

        Room found = bus.getRoom(data["room"].str);
        if (found is null || !found.visible(profile.name))
        {
            respondError(output, 404, "Unknown room");
            return Nullable!Schedule.init;
        }

        room = found.name;
    }
    else if ("room" in data.object && !data["room"].isNull)
        throw new InvalidInputException("Only room schedules take a room");

    string at;
    long every;
    long next;
    if (type == EventType.Clock)
    {
        bool hasAt = "at" in data.object && !data["at"].isNull;
        bool hasEvery = "every" in data.object && !data["every"].isNull;
        if (hasAt == hasEvery)
            throw new InvalidInputException("A clock schedule needs either at or every");

        long timestamp = Clock.currTime(UTC()).stdTime / stdTimeTicksPerMillisecond;
        if (hasAt)
        {
            if (data["at"].type != JSONType.string)
                throw new InvalidInputException("at must be an ISO-8601 timestamp");

            SysTime time;
            try
                time = SysTime.fromISOExtString(data["at"].str);
            catch (Exception)
                throw new InvalidInputException("at must be an ISO-8601 timestamp");

            time = time.toUTC();
            if (time.stdTime / stdTimeTicksPerMillisecond <= timestamp)
                throw new InvalidInputException("at must be in the future");

            at = time.toISOExtString();
            next = time.stdTime / stdTimeTicksPerMillisecond;
        }
        else
        {
            if (data["every"].type != JSONType.integer || data["every"].integer < 1 ||
                data["every"].integer > maxEvery)
                throw new InvalidInputException("every must be a number of seconds up to "~maxEvery.to!string);

            every = data["every"].integer;
            next = timestamp + every * 1000;
        }
    }
    else if (("at" in data.object && !data["at"].isNull) || ("every" in data.object && !data["every"].isNull))
        throw new InvalidInputException("Only clock schedules take at or every");

    return Nullable!Schedule(scheduleStore.add(profile, Schedule.create(type, from, room, at, every, next)));
}
