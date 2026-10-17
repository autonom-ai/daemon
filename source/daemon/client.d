module daemon.client;

import daemon.agent;
import daemon.coord;
import daemon.events.event : EventType;
import daemon.exception;
import daemon.interop.devin.db : readSessionMessages;
import daemon.interop.bridge;
import daemon.interop.session;
import daemon.http;
import daemon.runtime;
import daemon.storage;
import serverino;

import core.time : MonoTime, seconds;
import std.algorithm : sort;
import std.file : exists;
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
    ret["humanEvents"] = JSONValue(cast(long)events.unread(profileStore.get(HUMAN_NAME)).length);
    string directory = request.get.read("directory");
    Session[] sessions = bridge.list();
    foreach (profile; profileStore.list())
    {
        bool managed = profile.session !is null && bridge.access.managed(profile.session.id);
        JSONValue record = profile.toJSON(false);
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

    foreach (session; sessions)
    {
        JSONValue record = session.toJSON(false);
        if (!record["directory"].str.length && session.execution !is null)
            record["directory"] = JSONValue(session.execution.workspace);
        if (directory.length && record["directory"].str != directory)
            continue;

        Profile profile = profileStore.profileFor(session.id);
        record["profile"] = profile is null ? JSONValue(null) : JSONValue(profile.name);
        ret["sessions"].array ~= record;
    }

    Call[] runs = bridge.listCalls(directory);
    foreach (execution; runs.length > 100 ? runs[$-100..$] : runs)
    {
        if (execution.kind != CallKind.Remove)
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
    Call execution = bridge.execution(id);
    string session = execution is null ? id : execution.sessionId;
    if (execution is null && !bridge.access.managed(session))
    {
        respondError(output, 404, "Session is not managed by Autonom");
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

    if (modelsCatalog.length && MonoTime.currTime - modelsFetched < 60.seconds)
    {
        respond(output, parseJSON(modelsCatalog));
        return;
    }

    try
    {
        string catalog = bridge.run(["models", "list", "--format", "json"]);
        modelsCatalog = catalog.idup;
        modelsFetched = MonoTime.currTime;
        respond(output, parseJSON(catalog));
    }
    catch (Exception)
        respondError(output, 503, "Could not retrieve the Bridge model catalog");
}

private:

string modelsCatalog;
MonoTime modelsFetched;

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

    ret.sort!((left, right) => left.timestamp != right.timestamp ? left.timestamp < right.timestamp :
        left.from == HUMAN_NAME && right.from != HUMAN_NAME);
    return ret;
}
