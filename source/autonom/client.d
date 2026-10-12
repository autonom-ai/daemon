module autonom.client;

import autonom.agent;
import autonom.coord;
import autonom.events.event : EventType;
import autonom.exception;
import autonom.interop.devin.db : readSessionMessages;
import autonom.interop.execution;
import autonom.interop.session;
import autonom.server;
import autonom.storage;
import serverino;

import std.algorithm : sort;
import std.conv : to;
import std.file : exists, getSize;
import std.json : JSONType, JSONValue, parseJSON;

public:

@endpoint @route!"/api/client/state"
void clientState(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    JSONValue ret = JSONValue.emptyObject;
    ret["profiles"] = JSONValue.emptyArray;
    ret["sessions"] = JSONValue.emptyArray;
    ret["runs"] = JSONValue.emptyArray;
    ret["rooms"] = JSONValue.emptyArray;
    ret["permissions"] = permissions.pending();
    ret["humanEvents"] = JSONValue(cast(long)events.unread(profileStore.get(HUMAN_NAME)).length);
    string directory = request.get.read("directory");
    foreach (profile; profileStore.list())
    {
        bool managed = profile.session !is null && bridge.access.managed(profile.session.id);
        JSONValue record = profile.toJSON();
        record["managed"] = JSONValue(managed);
        record["events"] = JSONValue(cast(long)events.unread(profile).length);
        record["schedules"] = JSONValue(cast(long)scheduleStore.list(profile).length);
        Entry[] direct = conversation(profile.name);
        size_t cursor = bus.cursor(HUMAN_NAME, "direct:"~profile.name);
        long unread;
        foreach (i, entry; direct)
        {
            if (i >= cursor && entry.from != HUMAN_NAME)
                unread++;
        }

        record["unread"] = JSONValue(unread);
        ret["profiles"].array ~= record;
    }

    foreach (id; bridge.access.ids)
    {
        Session session = bridge.findSession(id);
        if (session is null)
            continue;

        JSONValue record = session.toJSON();
        if (!record["directory"].str.length && session.execution !is null)
            record["directory"] = JSONValue(session.execution.workspace);
        if (directory.length && record["directory"].str != directory)
            continue;

        Profile profile = profileStore.profileFor(id);
        record["profile"] = profile is null ? JSONValue(null) : JSONValue(profile.name);
        ret["sessions"].array ~= record;
    }

    Execution[] runs = bridge.listExecutions(directory);
    foreach (execution; runs.length > 100 ? runs[$-100..$] : runs)
    {
        if (execution.kind != ExecutionKind.Remove)
            ret["runs"].array ~= execution.toJSON();
    }

    foreach (room; bus.visibleRooms(HUMAN_NAME))
    {
        JSONValue record = bus.roomEntry(room, profileStore.get(HUMAN_NAME));
        record["membership"] = room.toJSON();
        ret["rooms"].array ~= record;
    }

    respond(output, ret);
}

@endpoint @route!"/api/client/messages"
void clientMessages(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    string source = request.get.read("source");
    string target = request.get.read("target");
    Entry[] entries;
    Profile human = profileStore.get(HUMAN_NAME);
    if (source == "room")
    {
        Room room = bus.getRoom(target);
        if (room is null)
            throw new InvalidInputException("Unknown room");

        Stream stream = bus.roomMessages(room);
        entries = stream.entries;
        bus.advance(HUMAN_NAME, stream.name, entries.length);
    }
    else if (source == "dm")
    {
        if (profileStore.get(target) is null || target == HUMAN_NAME)
            throw new InvalidInputException("Unknown recipient");

        entries = conversation(target);
        bus.advance(HUMAN_NAME, "direct:"~target, entries.length);
    }
    else if (source == "pings")
    {
        Stream stream = bus.pings(HUMAN_NAME);
        entries = stream.entries;
        bus.advance(HUMAN_NAME, stream.name, entries.length);
        events.clear(human, EventType.Ping);
    }
    else
        throw new InvalidInputException("Source must be room, dm, or pings");

    JSONValue ret = JSONValue.emptyArray;
    foreach (entry; entries.length > 500 ? entries[$-500..$] : entries)
        ret.array ~= entry.toJSON();

    respond(output, ret);
}

@endpoint @route!"/api/client/events"
void clientEvents(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    Profile profile = profileStore.get(request.get.read("profile", HUMAN_NAME));
    if (profile is null)
        throw new InvalidInputException("Unknown profile");

    JSONValue ret = JSONValue.emptyArray;
    foreach (event; events.unread(profile))
        ret.array ~= event.toJSON();

    respond(output, ret);
}

@endpoint @route!(matchesPath!"/api/client/transcript/<id>")
void clientTranscript(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    string id = routeParameter!"/api/client/transcript/<id>"(request);
    Execution execution = bridge.execution(id);
    string session = execution is null ? id : execution.sessionId;
    if (execution is null && !bridge.access.managed(session))
    {
        respond(output, JSONValue(["error": JSONValue("Session is not managed by Autonom")]), 404);
        return;
    }

    JSONValue ret = JSONValue.emptyObject;
    ret["messages"] = JSONValue.emptyArray;
    ret["execution"] = JSONValue(null);
    if (session.length)
    {
        Session found = bridge.findSession(session);
        if (execution is null && found !is null)
            execution = found.execution;

        ret["session"] = found is null ? JSONValue(null) : found.toJSON();
        ret["messages"] = readSessionMessages(bridge.sessionDatabase, session);
    }
    else
        ret["session"] = JSONValue(null);

    if (execution !is null)
    {
        ret["execution"] = execution.toJSON();
        if (!ret["messages"].array.length && exists(execution.exportPath) && getSize(execution.exportPath))
            ret["messages"] = exportedMessages(execution);
        if (!ret["messages"].array.length && !execution.running && exists(execution.outputPath))
        {
            ret["messages"].array ~= JSONValue([
                "role": JSONValue("assistant"),
                "content": JSONValue(readText(execution.outputPath, 1024 * 1024))
            ]);
        }
    }

    respond(output, ret);
}

@endpoint @route!"/api/client/models"
void clientModels(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    try
        respond(output, parseJSON(bridge.run(["models", "list", "--format", "json"])));
    catch (Exception)
        respond(output, JSONValue(["error": JSONValue("Could not retrieve the Devin model catalog")]), 503);
}

private:

Entry[] conversation(string profile)
{
    Entry[] ret;
    foreach (entry; bus.directMessages(HUMAN_NAME).entries)
    {
        if (entry.from == profile)
            ret ~= entry;
    }

    foreach (entry; bus.directMessages(profile).entries)
    {
        if (entry.from == HUMAN_NAME)
            ret ~= entry;
    }

    ret.sort!((left, right) => left.timestamp < right.timestamp);
    return ret;
}

JSONValue exportedMessages(Execution execution)
{
    JSONValue ret = JSONValue.emptyArray;
    JSONValue data = readJSON(execution.exportPath, 16 * 1024 * 1024);
    if (data.type != JSONType.object || "steps" !in data.object || data["steps"].type != JSONType.array)
        return ret;

    foreach (step; data["steps"].array)
    {
        if (step.type != JSONType.object || "source" !in step.object || step["source"].type != JSONType.string ||
            step["source"].str == "system")
            continue;

        JSONValue message = JSONValue.emptyObject;
        message["role"] = JSONValue(step["source"].str == "agent" ? "assistant" : step["source"].str);
        foreach (field; ["message", "tool_calls", "observation", "reasoning_content", "timestamp"])
        {
            if (field in step.object)
                message[field == "message" ? "content" : field] = step[field];
        }

        ret.array ~= message;
        if (ret.array.length == 500)
            break;
    }

    return ret;
}
