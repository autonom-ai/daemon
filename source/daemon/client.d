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
import std.path : buildPath;

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

    try
    {
        string id = routeParameter!"/api/client/transcript/<id>"(request);
        Call execution = bridge.execution(id);
    JSONValue executionJson = execution !is null ? execution.toJSON() : bridge.executionRecord(id);

    string session;
    if (execution !is null && execution.sessionId.length)
        session = execution.sessionId;
    else
    {
        string mapped = bridge.sessionForExecution(id);
        session = mapped.length ? mapped : id;
    }

    string executionOut = buildPath(bridge.executionDir, id ~ ".out");
    string executionErr = buildPath(bridge.executionDir, id ~ ".err");
    bool isKnownExecution = execution !is null || !executionJson.isNull ||
        exists(executionOut) || exists(executionErr);

    bool isKnownSession = session.length && (
        bridge.access.managed(session) ||
        bridge.findSession(session) !is null ||
        exists(bridge.logPath(session))
    );

    if (!isKnownExecution && !isKnownSession)
    {
        respondError(output, 404, "Session is not managed by Autonom");
        return;
    }

    JSONValue ret = JSONValue.emptyObject;
    ret["messages"] = JSONValue.emptyArray;
    ret["execution"] = executionJson.isNull ? JSONValue(null) : executionJson;

    if (session.length && isKnownSession)
    {
        Session found = bridge.findSession(session);
        if (execution is null && found !is null && found.execution !is null)
        {
            execution = found.execution;
            if (ret["execution"].isNull)
                ret["execution"] = execution.toJSON();
        }

        ret["session"] = found is null ? JSONValue(["id": JSONValue(session)]) : found.toJSON();
        try
            ret["messages"] = readSessionMessages(bridge.sessionDatabase, session);
        catch (Exception)
            ret["messages"] = JSONValue.emptyArray;

        if (!ret["messages"].array.length && exists(bridge.logPath(session)))
        {
            try
            {
                string sessionLog = readText(bridge.logPath(session), 1024 * 1024);
                if (sessionLog.length)
                {
                    ret["messages"].array ~= JSONValue([
                        "role": JSONValue("assistant"),
                        "content": JSONValue(sessionLog)
                    ]);
                }
            }
            catch (Exception)
            {
            }
        }
    }
    else
        ret["session"] = JSONValue(null);

    if (!ret["messages"].array.length)
    {
        if (exists(executionOut))
        {
            try
            {
                string outContent = readText(executionOut, 1024 * 1024);
                if (outContent.length)
                {
                    ret["messages"].array ~= JSONValue([
                        "role": JSONValue("assistant"),
                        "content": JSONValue(outContent)
                    ]);
                }
            }
            catch (Exception)
            {
            }
        }
        else if (execution !is null && !execution.running && exists(execution.outputPath))
        {
            try
            {
                string outContent = readText(execution.outputPath, 1024 * 1024);
                if (outContent.length)
                {
                    ret["messages"].array ~= JSONValue([
                        "role": JSONValue("assistant"),
                        "content": JSONValue(outContent)
                    ]);
                }
            }
            catch (Exception)
            {
            }
        }
    }

        respond(output, ret);
    }
    catch (Exception error)
    {
        import std.stdio : stderr;
        stderr.writeln("CLIENT TRANSCRIPT FAILED: ", error.toString());
        respondError(output, 500, error.msg);
    }
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
