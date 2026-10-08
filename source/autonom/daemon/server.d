module autonom.daemon.server;

import CONFIG = autonom.config;
import PROFILES = autonom.profilestore;
import autonom.session.devin : Devin;
import serverino : Output, Request, ServerinoConfig, ServerinoProcess,
    endpoint, onServerInit, onWorkerException, onWorkerStart, route;

version (AutonomDaemon)
    import serverino : ServerinoMain;

import core.sys.posix.signal : kill, SIGTERM;
import core.thread : Thread;
import core.time : Duration, msecs;
import std.algorithm : startsWith;
import std.exception : ErrnoException, enforce;
import std.file : FileException;
import std.json : JSONValue, JSONType, parseJSON;
import std.process : environment, thisProcessID;

private:

bool stopping;

package(autonom):

CONFIG.Config configuration;
PROFILES.ProfileStore profileStore;

void respond(Output output, JSONValue body, ushort status = 200)
{
    output.status = status;
    output.addHeader("content-type", "application/json");
    output.addHeader("cache-control", "no-store");
    output ~= body.toString();
}

JSONValue readBody(Request request)
{
    enum MIME = "application/json";
    enum MAX_BODY = 64 * 1024;
    enforce(request.body.contentType == MIME || request.body.contentType.startsWith(MIME~";"),
        "Expected application/json");
    enforce(request.body.data.length <= MAX_BODY, "Request body is too large");
    JSONValue ret = parseJSON(request.body.data);
    enforce(ret.type == JSONType.object, "Expected a JSON object");
    return ret;
}

string readField(string FIELD)(Request request)
{
    JSONValue data = readBody(request);
    enforce(data.object.length == 1 && FIELD in data.object, "Expected only the "~FIELD~" field");
    enforce(data[FIELD].type == JSONType.string, FIELD~" must be a string");
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
            "workerPid": JSONValue(thisProcessID)
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

    enforce(readBody(request).object.length == 0, "Expected an empty JSON object");
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
    version (AutonomHttpTest)
        enum PORT = 18080;
    else
        enum PORT = 8080;

    return ServerinoConfig.create()
        .addListener("127.0.0.1", PORT)
        .setWorkers(1)
        .setMaxWorkerLifetime(Duration.max)
        .setMaxWorkerIdling(Duration.max);
}

@onWorkerStart void setupWorker()
{
    version (AutonomHttpTest)
        configuration = new CONFIG.Config(environment.get("AUTONOM_TEST_CONFIG"));
    else
        configuration = new CONFIG.Config(environment.get("AUTONOM_CONFIG", CONFIG.Config.defaultPath));

    profileStore = new PROFILES.ProfileStore(configuration, new Devin(configuration));
}

@onWorkerException bool handleException(Request request, Output output, Exception error)
{
    ushort status = cast(ErrnoException)error || cast(FileException)error ? 500 :
        cast(PROFILES.ProfileConflict)error ? 409 : 400;
    respond(output, JSONValue([
        "error": JSONValue(status == 500 ? "Could not access storage" : error.msg)
    ]), status);
    return true;
}

version (AutonomDaemon)
    mixin ServerinoMain!(CONFIG, PROFILES);
