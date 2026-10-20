module tests.http.common;

import tests.common;

import core.sync.mutex : Mutex;
import std.array : join;
import std.file : exists, readText, write;
import std.json : JSONValue;
import std.net.curl : CurlException;
import std.path : buildPath;
import std.process;
import std.stdio : File, stdin;

private __gshared Mutex daemonMutex;

shared static this()
{
    daemonMutex = new Mutex();
}

struct RunningDaemon
{
    Pid process;
    File log;
    bool ownsPort;

    void close()
    {
        scope(exit)
        {
            if (ownsPort)
            {
                ownsPort = false;
                daemonMutex.unlock();
            }
        }
        if (process !is null)
        {
            if (!tryWait(process).terminated)
            {
                kill(process);
                wait(process);
            }

            process = null;
        }

        if (log.isOpen)
            log.close();
    }
}

RunningDaemon startDaemon(Fixture fixture)
{
    daemonMutex.lock();
    requestToken = fixture.bridge.access.clientToken;
    hookTokens = null;
    RunningDaemon ret;
    ret.ownsPort = true;
    scope(failure)
        ret.close();
    string path = buildPath(fixture.root, "daemon.log");
    ret.log = File(path, "w");
    ret.process = spawnProcess(
        ["bin/autonom-daemon"],
        stdin,
        ret.log,
        ret.log,
        ["AUTONOM_CONFIG": fixture.path, "AUTONOM_PORT": "18080",
            "XDG_CONFIG_HOME": buildPath(fixture.root, "xdg-config")],
        Config.retainStdin | Config.retainStdout | Config.retainStderr
    );
    waitUntil(delegate bool() {
        if (tryWait(ret.process).terminated)
            throw new Exception(readText(path));

        try
            return request("/api/health")["pid"].integer == ret.process.processID;
        catch (CurlException)
            return false;
    });
    return ret;
}

string invokeHook(string command, JSONValue payload, int expected = 0)
{
    File input = File.tmpfile();
    File output = File.tmpfile();
    File errors = File.tmpfile();
    scope(exit)
    {
        input.close();
        output.close();
        errors.close();
    }

    input.write(payload.toString());
    input.rewind();
    int status = wait(spawnProcess(
        ["/bin/sh", "-c", command],
        input,
        output,
        errors,
        ["AUTONOM_PORT": "18080"],
        Config.retainStdin | Config.retainStdout | Config.retainStderr
    ));
    errors.rewind();
    if (status != expected)
        throw new Exception(cast(string)errors.byChunk(4096).join);

    output.rewind();
    return cast(string)output.byChunk(4096).join;
}

JSONValue hookSession(
    Fixture fixture,
    string id,
    string profile = null,
    bool identify = true,
    string prompt = null
)
{
    if (!exists(fixture.config.devinCommand))
        installFake(fixture);

    write(buildPath(fixture.root, "next-session-id"), id);
    JSONValue ret = request("/api/sessions", 202, JSONValue([
        "prompt": JSONValue(prompt.length ? prompt : "auth:"~id),
        "directory": JSONValue(fixture.root),
        "profile": JSONValue(profile.length ? profile : "")
    ]).toString());
    string tokenPath = buildPath(fixture.root, id~".token");
    waitUntil(delegate bool() {
        return exists(tokenPath);
    });
    hookTokens[id] = readText(tokenPath);
    if (identify)
    {
        request("/api/hooks/session-start", 200, JSONValue([
            "hook_event_name": JSONValue("SessionStart"),
            "session_id": JSONValue(id)
        ]).toString());
    }

    return ret;
}

void finishHookSession(JSONValue execution)
{
    request("/api/executions/"~execution["id"].str~"/stop", 202, "{}");
    waitForCall(execution);
}

JSONValue waitForCall(JSONValue accepted)
{
    string path = "/api/executions/"~accepted["id"].str;
    JSONValue ret;
    waitUntil(delegate bool() {
        ret = request(path);
        return ret["status"].str != "running" && ret["status"].str != "stopping";
    });
    return ret;
}
