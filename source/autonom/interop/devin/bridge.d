module autonom.interop.devin.bridge;

import autonom.config : Config;
import autonom.server : bridge, readLaunch, respond;
import autonom.interop.bridge : Bridge;
import autonom.interop.devin.session : DevinSession;
import autonom.interop.session : Session;
import autonom.storage : openFile;
import serverino : Output, Request, endpoint, route;

import core.stdc.errno : errno, EWOULDBLOCK;
import core.sys.posix.fcntl : O_RDONLY;
import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB;
import std.algorithm : canFind;
import std.exception : enforce, errnoEnforce;
import std.file : exists;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : Pid;
import std.stdio : File;

private:

enum string[] HOST_PREFIXES = [
    "ACP_",
    "ELECTRON_",
    "VSCODE_",
    "WINDSURF_"
];

public:

@endpoint @route!"/api/sessions"
void sessions(Request request, Output output)
{
    if (request.method == Request.Method.Get)
        respond(output, JSONValue(bridge.list(request.get.read("directory"))));
    else if (request.method == Request.Method.Post)
    {
        JSONValue data = readLaunch(request);
        Session session = DevinSession.start(
            bridge,
            data["prompt"].str,
            data["directory"].str,
            data["model"].str
        );
        respond(output, session.toJSON(), 201);
    }
    else
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
}

@endpoint @route!"/api/print"
void printSession(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    JSONValue data = readLaunch(request);
    respond(output, JSONValue(["reply": JSONValue(bridge.print(
        data["prompt"].str,
        data["directory"].str,
        data["model"].str
    ))]));
}

/// Devin CLI bridge.
class Devin : Bridge
{
private:
    string lockPath(string id) const
        => buildPath(sessionLockDir, id~".lock");

public:
    const string sessionLockDir;

    this(Config configuration)
    {
        super(configuration.devinCommand, buildPath(configuration.dataDir, "sessions"), HOST_PREFIXES);
        sessionLockDir = configuration.sessionLockDir;
    }

    static string[] arguments(string prompt, string model = null)
    {
        enforce(prompt.length && !prompt.canFind('\0'), "A prompt is required");
        enforce(!model.canFind('\0'), "Invalid model name");
        string[] ret = ["--print"];
        if (model.length)
            ret ~= ["--model", model];

        return ret~["--", prompt];
    }

    override DevinSession session(string id)
        => new DevinSession(id, this);

    override bool online(string id)
    {
        string path = lockPath(id);
        if (!exists(path))
            return false;

        File file = openFile(path, O_RDONLY);
        scope(exit)
            file.close();

        int result = flock(file.fileno, LOCK_EX | LOCK_NB);
        errnoEnforce(result == 0 || errno == EWOULDBLOCK, "Could not inspect session lock");
        return result != 0;
    }

    override void remove(string id)
    {
        run(["rm", "--force", "--", id]);
        removeLog(id);
    }

    /// Continues the session through a print, capturing its output in the session log.
    Pid resume(
        string id,
        string prompt,
        string directory,
        string model
    )
        => spawn(id, ["--resume", id]~arguments(prompt, model), directory);

    /// Runs a one-shot prompt and returns the reply.
    string print(string prompt, string directory, string model = null)
        => run(arguments(prompt, model), directory);

    /// Lists session IDs for a directory.
    string[] list(string directory = null)
    {
        string[] ret;
        foreach (JSONValue entry; parseJSON(run(["list", "--format", "json"], directory)).array)
            ret ~= entry["id"].str;

        return ret;
    }
}
