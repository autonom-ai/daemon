module daemon.server;

import daemon.exception;
import daemon.http;
import daemon.runtime;
import serverino;

import core.sys.posix.signal : kill, SIGTERM;
import core.thread : Thread;
import core.time : Duration, msecs;
import std.algorithm : startsWith;
import std.conv : to;
import std.json : JSONValue;
import std.process : environment, thisProcessID;

private:

bool stopping;

public:

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
