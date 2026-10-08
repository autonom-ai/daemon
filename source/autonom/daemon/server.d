module autonom.daemon.server;

import CONFIG = autonom.config;
import PROFILES = autonom.profilestore;
import autonom.session.devin : Devin;
import serverino;

import std.algorithm : startsWith;
import std.exception : ErrnoException, enforce;
import std.file : FileException;
import std.json : JSONValue, JSONType, parseJSON;
import std.process : environment;

package(autonom):

CONFIG.Config configuration;
PROFILES.ProfileStore profileStore;

void respond(Output output, JSONValue body, ushort status = 200)
{
    output.status = status;
    output.addHeader("content-type", "application/json");
    output ~= body.toString();
}

string readField(string FIELD)(Request request)
{
    enum MIME = "application/json";
    enum MAX_BODY = 64 * 1024;
    enforce(request.body.contentType == MIME || request.body.contentType.startsWith(MIME~";"),
        "Expected application/json");
    enforce(request.body.data.length <= MAX_BODY, "Request body is too large");
    JSONValue data = parseJSON(request.body.data);
    enforce(data.type == JSONType.object && data.object.length == 1 && FIELD in data.object,
        "Expected only the "~FIELD~" field");
    enforce(data[FIELD].type == JSONType.string, FIELD~" must be a string");
    return data[FIELD].str;
}

public:

@onServerInit ServerinoConfig setup()
{
    version (AutonomHttpTest)
        return ServerinoConfig.create().addListener("127.0.0.1", 18080).setWorkers(2);
    else
        return ServerinoConfig.create().addListener("127.0.0.1", 8080).setWorkers(2);
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
