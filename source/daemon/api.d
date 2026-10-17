module daemon.api;

import daemon.agent;
import daemon.agent.profile;
import daemon.agent.store;
import daemon.coord;
import daemon.coord.access;
import daemon.events;
import daemon.events.event;
import daemon.events.schedule;
import daemon.exception;
import daemon.hooks;
import daemon.http;
import daemon.interop.api;
import daemon.interop.bridge;
import daemon.interop.devin.db : readSessionMessages;
import daemon.interop.mcp;
import daemon.interop.session;
import daemon.policy.access;
import daemon.runtime;
import daemon.storage;
import serverino;

import core.sys.posix.signal : kill, SIGTERM;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : sort, startsWith;
import std.conv : to;
import std.file : exists;
import std.json : JSONType, JSONValue, parseJSON;
import std.meta : AliasSeq;
import std.path : buildPath;
import std.process : environment, thisProcessID;

private:

bool stopping;
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

public:

alias apiModules = AliasSeq!(
    daemon.agent.profile,
    daemon.agent.store,
    daemon.coord.access,
    daemon.events.event,
    daemon.events.schedule,
    daemon.hooks,
    daemon.policy.access,
    daemon.interop.api,
    daemon.interop.mcp
);

mixin ServerinoLoop!apiModules;

int runApiServer(string[] args = null)
{
    return mainServerinoLoop!OnMainThread(args);
}

void runApiServerAsync(string[] args = null)
{
    mainServerinoLoop!OnSecondaryThread(args);
}

@endpoint @route!"/api/health"
void health(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    respond(output, JSONValue([
        "status": JSONValue(stopping ? "stopping" : "ok"),
        "pid": JSONValue(ServerinoProcess.daemonPID),
        "workerPid": JSONValue(thisProcessID),
        "controlFile": JSONValue(bridge.access.tokenPath),
        "configFile": JSONValue(configuration.path)
    ]), stopping ? 503 : 200);
}

@endpoint @route!"/api/stop"
void stop(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    if (readBody(request).object.length != 0)
        throw new InvalidInputException("Expected an empty JSON object");
    if (!stopping)
        bridge.stopSessions();

    respond(output, JSONValue(["status": JSONValue("stopping")]), 202);
    if (stopping)
        return;

    stopping = true;
    new Thread({
        Thread.sleep(100.msecs);
        kill(ServerinoProcess.daemonPID, SIGTERM);
    }).start();
}

@onServerInit ServerinoConfig setup()
{
    return ServerinoConfig.create()
        .addListener("127.0.0.1", environment.get("AUTONOM_PORT", "8080").to!ushort)
        .setWorkers(1)
        .setMaxWorkerLifetime(Duration.max)
        .setMaxWorkerIdling(Duration.max)
        .setMaxRequestTime(Duration.max)
        .setMaxRequestSize(20 * 1024 * 1024);
}

@onWorkerStart void setupWorker()
{
    daemon.runtime.setup();
    refresh(Request.init);
    scheduler.start();
}

@endpoint @priority(200)
void authorize(Request request, Output output)
{
    if (request.path == "/api/health" || request.path.startsWith("/api/hooks/"))
        return;
    if (bridge.access.client(request.header.read("x-autonom-client")))
        return;

    if (request.path.startsWith("/api/mcp/"))
    {
        if (!bridge.access.mcpSession(request.header.read("x-autonom-mcp")).length)
            respondError(output, 403, "Autonom access requires a managed session capability");
        return;
    }

    string session = request.header.read("x-autonom-session");
    if (!session.length)
        session = request.get.read("session");

    bool coordination = request.path == "/api/profiles" || request.path.startsWith("/api/profiles/") ||
        request.path == "/api/rooms" || request.path.startsWith("/api/rooms/") ||
        request.path == "/api/messages" || request.path == "/api/events" ||
        request.path == "/api/schedules" || request.path.startsWith("/api/schedules/");
    bool granted = bridge.authenticate(request.header.read("x-autonom-run"), session) !is null;
    if (!granted)
    {
        string bound = bridge.access.mcpSession(request.header.read("x-autonom-mcp"));
        granted = bound.length && (!session.length || bound == session);
    }
    if (!coordination || request.path == "/api/schedules/refresh" || !granted)
        respondError(output, 403, "Autonom access requires a managed session capability");
}

@endpoint @priority(100)
void refresh(Request request)
{
    bridge.sweepObserved();
    foreach (id; bridge.collect())
        profileStore.unlinkSession(id);
    foreach (execution; bridge.listCalls())
    {
        if (!execution.profileName.length || !execution.sessionId.length || !bridge.access.managed(execution.sessionId))
            continue;
        if (profileStore.assigned(execution.sessionId))
            continue;

        profileStore.register(execution.profileName, execution.sessionId);
    }

    if (scheduler !is null)
        scheduler.refresh();
}

@onWorkerStop void closeWorker()
{
    daemon.runtime.close();
}

@onWorkerException bool handleException(Request request, Output output, Exception error)
{
    ushort status = cast(InvalidInputException)error ? 400 : cast(ConflictException)error ? 409 :
        cast(BackendException)error ? 503 : 500;
    respondError(output, status, status == 500 ? "Internal server error" : error.msg);
    return true;
}

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
