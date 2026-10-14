module daemon.server;

import daemon.agent;
import daemon.config;
import daemon.coord;
import daemon.events;
import daemon.exception;
import daemon.policy;
import daemon.interop.devin;
import daemon.interop.permission : PermissionStore;
import daemon.worktree;
import serverino;

import core.sys.posix.signal : kill, SIGTERM;
import core.thread : Thread;
import core.time : Duration, msecs;
import std.algorithm : canFind, endsWith, startsWith;
import std.array : join;
import std.conv : to;
import std.json : JSONValue, JSONType, parseJSON;
import std.process : environment, thisProcessID;
import std.string : indexOf, toUpper;

private:

bool stopping;

package(daemon):

Config configuration;
Devin bridge;
ProfileStore profileStore;
Policy policy;
Bus bus;
EventStore events;
ScheduleStore scheduleStore;
Scheduler scheduler;
PermissionStore permissions;
WorktreeManager worktreeManager;

void respond(Output output, JSONValue body, ushort status = 200)
{
    output.status = status;
    output.addHeader("content-type", "application/json");
    output.addHeader("cache-control", "no-store");
    output ~= body.toString();
}

bool acceptMethod(Request request, Output output, Request.Method[] methods)
{
    if (methods.canFind(request.method))
        return true;

    string[] names;
    foreach (method; methods)
        names ~= method.to!string.toUpper;

    output.addHeader("allow", names.join(", "));
    respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
    return false;
}

string routeParameter(string PATTERN)(const Request request)
{
    enum START = PATTERN.indexOf('<');
    enum END = PATTERN.indexOf('>');
    static assert(START >= 0 && END > START && PATTERN[END + 1..$].indexOf('<') < 0);
    enum PREFIX = PATTERN[0..START];
    enum SUFFIX = PATTERN[END + 1..$];
    if (!request.path.startsWith(PREFIX) || !request.path.endsWith(SUFFIX) ||
        request.path.length <= PREFIX.length + SUFFIX.length)
        return null;

    string ret = request.path[PREFIX.length..$-SUFFIX.length];
    return ret.canFind('/') ? null : ret;
}

bool matchesPath(string PATTERN)(const Request request)
    => routeParameter!PATTERN(request).length != 0;

JSONValue readBody(Request request, size_t limit = 64 * 1024)
{
    enum MIME = "application/json";
    if (request.body.contentType != MIME && !request.body.contentType.startsWith(MIME~";"))
        throw new InvalidInputException("Expected application/json");
    if (request.body.data.length > limit)
        throw new InvalidInputException("Request body is too large");

    JSONValue ret;
    try
        ret = parseJSON(request.body.data);
    catch (Exception)
        throw new InvalidInputException("Invalid JSON body");

    if (ret.type != JSONType.object)
        throw new InvalidInputException("Expected a JSON object");

    return ret;
}

JSONValue readLaunch(Request request)
{
    JSONValue ret = readBody(request);
    if ("prompt" !in ret.object || "directory" !in ret.object)
        throw new InvalidInputException("Expected prompt and directory");
    foreach (name, value; ret.object)
    {
        if (name == "trusted" && (value.type == JSONType.true_ || value.type == JSONType.false_))
            continue;
        if ((name != "prompt" && name != "directory" && name != "model" && name != "profile" && name != "mode") ||
            value.type != JSONType.string)
            throw new InvalidInputException("Invalid session launch field");
    }

    foreach (field; ["model", "profile", "mode"])
    {
        if (field !in ret.object)
            ret[field] = JSONValue("");
    }

    if ("trusted" !in ret.object)
        ret["trusted"] = JSONValue(false);

    return ret;
}

string readField(string FIELD)(Request request)
{
    JSONValue data = readBody(request);
    if (data.object.length != 1 || FIELD !in data.object)
        throw new InvalidInputException("Expected only the "~FIELD~" field");
    if (data[FIELD].type != JSONType.string)
        throw new InvalidInputException(FIELD~" must be a string");

    return data[FIELD].str;
}

public:

@endpoint @route!"/api/health"
void health(Request request, Output output)
{
    if (request.method == Request.Method.Get)
        respond(output, JSONValue([
            "status": JSONValue(stopping ? "stopping" : "ok"),
            "pid": JSONValue(ServerinoProcess.daemonPID),
            "workerPid": JSONValue(thisProcessID),
            "controlFile": JSONValue(bridge.access.tokenPath),
            "configFile": JSONValue(configuration.path)
        ]), stopping ? 503 : 200);
    else
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
}

@endpoint @route!"/api/stop"
void stop(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

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
        .setMaxRequestTime(Duration.max);
}

@onWorkerStart void setupWorker()
{
    configuration = new Config(environment.get("AUTONOM_CONFIG", Config.defaultPath));
    bridge = new Devin(configuration);
    profileStore = new ProfileStore(configuration, bridge);
    events = new EventStore(configuration, profileStore);
    bus = new Bus(configuration, profileStore);
    scheduleStore = new ScheduleStore(configuration, profileStore);
    scheduler = new Scheduler(configuration, bridge, profileStore, events, scheduleStore);
    policy = new Policy(configuration);
    permissions = new PermissionStore();
    worktreeManager = new WorktreeManager(configuration);
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

    string session = request.header.read("x-autonom-session");
    if (!session.length)
        session = request.get.read("session");

    bool coordination = request.path == "/api/profiles" || request.path.startsWith("/api/profiles/") ||
        request.path == "/api/rooms" || request.path.startsWith("/api/rooms/") ||
        request.path == "/api/messages" || request.path == "/api/events" ||
        request.path == "/api/schedules" || request.path.startsWith("/api/schedules/") ||
        request.path.startsWith("/api/permissions/");
    if (!coordination || request.path == "/api/schedules/refresh" ||
        bridge.authenticate(request.header.read("x-autonom-run"), session) is null)
        respond(output, JSONValue(["error": JSONValue("Autonom access requires a managed session capability")]), 403);
}

@endpoint @priority(100)
void refresh(Request request)
{
    foreach (id; bridge.collect())
        profileStore.unlinkSession(id);
    foreach (execution; bridge.listExecutions())
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
    if (scheduler !is null)
        scheduler.stop();
    if (bridge !is null)
        bridge.close();
}

@onWorkerException bool handleException(Request request, Output output, Exception error)
{
    ushort status = cast(InvalidInputException)error ? 400 : cast(ConflictException)error ? 409 :
        cast(BackendException)error ? 503 : 500;
    respond(output, JSONValue([
        "error": JSONValue(status == 500 ? "Internal server error" : error.msg)
    ]), status);
    return true;
}
