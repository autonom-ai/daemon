module autonom.interop.devin.bridge;

import autonom.config : Config;
import autonom.exception : BackendFailure, Conflict, InvalidInput;
import autonom.interop.bridge : Bridge;
import autonom.interop.devin.session : DevinSession;
import autonom.interop.execution : Execution, ExecutionKind;
import autonom.interop.session : Session;
import autonom.server : acceptMethod, bridge, readLaunch, respond;
import autonom.storage : openFile;
import serverino : Output, Request, endpoint, route;

import core.stdc.errno : errno, EWOULDBLOCK;
import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB;
import core.sys.posix.fcntl : O_RDONLY;
import std.algorithm : canFind;
import std.exception : enforce, errnoEnforce;
import std.file : exists, isDir;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
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
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    if (request.method == Request.Method.Get)
        respond(output, JSONValue(bridge.list(request.get.read("directory"))));
    else
    {
        JSONValue data = readLaunch(request);
        respond(output, bridge.start(data["prompt"].str, data["directory"].str, data["model"].str).toJSON(), 202);
    }
}

@endpoint @route!"/api/print"
void printSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readLaunch(request);
    respond(output, bridge.print(data["prompt"].str, data["directory"].str, data["model"].str).toJSON(), 202);
}

/// Devin CLI bridge.
class Devin : Bridge
{
private:
    string lockPath(string id) const
        => buildPath(sessionLockDir, id~".lock");

    Execution submit(
        ExecutionKind kind,
        string prompt,
        string directory,
        string model,
        string id = null
    )
    {
        enforce!InvalidInput(directory.length && exists(directory) && isDir(directory),
            "An existing working directory is required");
        string[] args = arguments(prompt, model);
        Execution ret = newExecution(kind, directory, model, id);
        args = args[0..$-2]~["--export", ret.exportPath]~args[$-2..$];
        if (id.length)
            args = ["--resume", id]~args;

        return launch(ret, args);
    }

protected:
    override Session createSession(string id)
        => new DevinSession(id, this);

public:
    const string sessionLockDir;

    this(Config configuration)
    {
        super(configuration.devinCommand, buildPath(configuration.dataDir, "sessions"), HOST_PREFIXES);
        sessionLockDir = configuration.sessionLockDir;
        collect();
    }

    static string[] arguments(string prompt, string model = null)
    {
        enforce!InvalidInput(prompt.length && !prompt.canFind('\0'), "A prompt is required");
        enforce!InvalidInput(!model.canFind('\0'), "Invalid model name");
        string[] ret = ["--print"];
        if (model.length)
            ret ~= ["--model", model.idup];

        return ret~["--", prompt.idup];
    }

    override bool online(string id)
    {
        Session.validateId(id);
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

    override Execution remove(string id)
    {
        Session session = this.session(id);
        if (session.isRunning() && session.execution.kind == ExecutionKind.Remove)
            return session.execution;

        enforce!Conflict(session.isRunning() || !online(id), "Cannot remove a session owned by another process");
        Execution ret = newExecution(ExecutionKind.Remove, null, null, session.id);
        launch(ret, ["rm", "--force", "--", session.id], session.execution);
        session.bindExecution(ret);
        return ret;
    }

    /// Continues the session through a print, capturing its output in the session log.
    Execution resume(
        string id,
        string prompt,
        string directory,
        string model
    )
        => submit(ExecutionKind.Resume, prompt, directory, model, id);

    /**
     * Starts a new session through a print, returning its execution handle.
     *
     * The print reply is written to the session log.
     */
    Execution start(string prompt, string directory, string model = null)
        => submit(ExecutionKind.Start, prompt, directory, model);

    /// Runs a one-shot prompt asynchronously; its execution exposes the completed reply.
    Execution print(string prompt, string directory, string model = null)
        => submit(ExecutionKind.Print, prompt, directory, model);

    /// Lists session IDs for a directory and discovers their canonical handles.
    string[] list(string directory = null)
    {
        JSONValue data;
        try
            data = parseJSON(run(["list", "--format", "json"], directory));
        catch (Exception)
            throw new BackendFailure("Could not list backend sessions");

        enforce!BackendFailure(data.type == JSONType.array, "Invalid backend session list");
        string[] ret;
        foreach (entry; data.array)
        {
            enforce!BackendFailure(entry.type == JSONType.object && "id" in entry.object &&
                entry["id"].type == JSONType.string, "Invalid backend session list");
            Session.validateId(entry["id"].str);
            ret ~= session(entry["id"].str).id;
        }

        return ret;
    }
}
