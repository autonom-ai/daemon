/// Single-worker assembly of the Autonom HTTP API, domain stores, scheduler, bridge, and policy engine.
module daemon.api;

import daemon.agent.api;
import daemon.agent.store;
import daemon.agent.starts : ProfileStarts;
import daemon.agent;
import daemon.config;
import daemon.coord.messages;
import daemon.coord.rooms;
import daemon.coord;
import daemon.events.api;
import daemon.events.event;
import daemon.events.schedule;
import daemon.events;
import daemon.exception;
import daemon.hooks;
import daemon.http;
import daemon.interop.api;
import daemon.interop.access : Access;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.calls;
import daemon.interop.devin.connection;
import daemon.interop.devin.hooks : installHooks;
import daemon.interop.devin.session.api;
import daemon.interop.devin.session.control;
import daemon.interop.devin.session.permissions;
import daemon.interop.devin.session.transcript;
import daemon.interop.devin.session;
import daemon.mcp;
import daemon.policy.access;
import daemon.policy;
import daemon.worker : WorkerWake;
static import daemon.interop.devin.bridge;

import serverino;

import core.sys.posix.signal : kill, SIGTERM;
import core.thread : Thread;
import core.time : Duration, msecs;
import std.algorithm : startsWith;
import std.conv : to;
import std.json : JSONValue;
import std.meta : AliasSeq;
import std.process : environment, thisProcessID;

private bool stopping;

// Worker-owned domain singletons
Config configuration;
Bridge bridge;
ProfileStore profileStore;
ProfileStarts profileStarts;
Policy policy;
Bus bus;
EventStore events;
ScheduleStore scheduleStore;
Scheduler scheduler;
private WorkerWake workerWake;

void setupDomain()
{
    configuration = Config.get(environment.get("AUTONOM_CONFIG", Config.defaultPath));
    installHooks();
    Access access = new Access(configuration.dataDir);
    workerWake = new WorkerWake(environment.get("AUTONOM_PORT", "8080"), access.clientToken);
    bridge = new Bridge(configuration, access, &workerWake.notify);
    profileStore = new ProfileStore(configuration, bridge);
    profileStarts = new ProfileStarts(profileStore, bridge);
    events = new EventStore(configuration, profileStore);
    bus = new Bus(configuration, profileStore);
    scheduleStore = new ScheduleStore(configuration, profileStore);
    scheduler = new Scheduler(configuration, bridge, profileStore, events, scheduleStore, profileStarts);
    policy = new Policy(configuration);

    Bus.set(bus);
    ProfileStore.set(profileStore);
    Config.set(configuration);
}

void closeDomain()
{
    if (scheduler !is null)
        scheduler.stop();
    if (workerWake !is null)
        workerWake.stop();
    if (profileStarts !is null)
        profileStarts.close();
    if (bridge !is null)
        bridge.close();
}

alias apiModules = AliasSeq!(
    daemon.agent.api,
    daemon.coord.rooms,
    daemon.coord.messages,
    daemon.events.api,
    daemon.hooks,
    daemon.policy.access,
    daemon.interop.api,
    daemon.interop.devin.connection,
    daemon.interop.devin.session.api,
    daemon.interop.devin.session.control,
    daemon.interop.devin.session.permissions,
    daemon.interop.devin.session.transcript,
    daemon.mcp
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
    scope(failure)
        closeDomain();

    setupDomain();
    refresh(Request.init);
    scheduler.start();
    workerWake.start();
}

/// Authenticated internal wake endpoint; refresh runs on the worker before this handler.
@endpoint @route!"/api/worker/refresh"
void refreshWorker(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;
    if (readBody(request).object.length != 0)
        throw new InvalidInputException("Expected an empty JSON object");

    respond(output, JSONValue.emptyObject);
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
    foreach (id; bridge.collect())
        profileStore.unlinkSession(id);
    if (profileStarts.refresh())
        workerWake.notify();

    if (scheduler !is null)
        scheduler.refresh();
}

@onWorkerStop void closeWorker()
{
    closeDomain();
}

@onWorkerException bool handleException(Request request, Output output, Exception error)
{
    ushort status = cast(InvalidInputException)error ? 400 : cast(ConflictException)error ? 409 :
        cast(BackendException)error ? 503 : 500;
    respondError(output, status, status == 500 ? "Internal server error" : error.msg);
    return true;
}
