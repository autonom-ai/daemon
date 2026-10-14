module daemon.interop.devin.bridge;

import daemon.agent : Profile, validName;
import daemon.config;
import daemon.exception;
import daemon.interop.bridge;
import daemon.interop.devin.db : SessionMetadata, readSessionMetadata;
import daemon.interop.devin.session;
import daemon.interop.execution;
import daemon.interop.session;
import daemon.server : acceptMethod, bridge, matchesPath, profileStore, readBody, readField, readLaunch,
    respond, routeParameter;
import daemon.storage;
import serverino;

import core.stdc.errno : errno, EWOULDBLOCK;
import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB;
import core.sys.posix.fcntl : O_RDONLY;
import std.algorithm : canFind;
import std.base64 : Base64;
import std.conv : to;
import std.exception : ErrnoException;
import std.file;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.stdio : File;
import std.string : toLower;

public:

@endpoint @route!"/api/sessions"
void sessions(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    if (request.method == Request.Method.Get)
        respond(output, JSONValue(bridge.access.ids));
    else
    {
        JSONValue data = readLaunch(request);
        string profileName = data["profile"].str.toLower;
        if (profileName.length)
        {
            if (!validName(profileName) || profileName == "human")
                throw new InvalidInputException("Invalid profile name");

            Profile profile = profileStore.get(profileName);
            if (profile !is null && profile.session !is null &&
                (profile.session.isRunning() || bridge.online(profile.session.id)))
                throw new ConflictException("Profile is already active");
            foreach (execution; bridge.listExecutions())
            {
                if (execution.running && execution.profileName == profileName)
                    throw new ConflictException("Profile already has a starting session");
            }
        }

        respond(output, bridge.start(
            data["prompt"].str,
            data["directory"].str,
            data["model"].str,
            data["mode"].str,
            data["trusted"].boolean,
            profileName
        ).toJSON(), 202);
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

@endpoint @route!"/api/acp"
void startAcp(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readBody(request);
    foreach (field; ["directory", "model"])
    {
        if (field !in data.object || data[field].type != JSONType.string)
            throw new InvalidInputException("Expected ACP directory and model");
    }

    string session;
    if ("sessionId" in data.object)
    {
        if (data["sessionId"].type != JSONType.string)
            throw new InvalidInputException("Invalid ACP session ID");

        session = data["sessionId"].str;
    }

    respond(output, bridge.acp(data["directory"].str, data["model"].str, session).toJSON(), 202);
}

@endpoint @route!(matchesPath!"/api/acp/<id>")
void acpFrames(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    Execution execution = bridge.execution(routeParameter!"/api/acp/<id>"(request));
    if (execution is null || execution.kind != ExecutionKind.Acp)
        throw new InvalidInputException("Unknown ACP execution");
    if (request.method == Request.Method.Post)
    {
        JSONValue frame = readBody(request, 16 * 1024 * 1024);
        if ("jsonrpc" !in frame.object || frame["jsonrpc"] != JSONValue("2.0"))
            throw new InvalidInputException("Expected a JSON-RPC frame");

        execution.sendFrame(frame.toString());
        respond(output, JSONValue.emptyObject, 202);
        return;
    }

    execution.renewAcp();
    ulong offset;
    try
        offset = request.get.read("offset", "0").to!ulong;
    catch (Exception)
        throw new InvalidInputException("Invalid ACP output offset");

    ubyte[] data;
    if (exists(execution.outputPath))
    {
        File file = openFile(execution.outputPath, O_RDONLY);
        scope(exit)
            file.close();

        if (offset > file.size)
            throw new InvalidInputException("ACP output offset is past the end");

        file.seek(offset);
        ubyte[65536] buffer;
        data = file.rawRead(buffer).dup;
    }

    respond(output, JSONValue([
        "offset": JSONValue(offset + data.length),
        "data": JSONValue(Base64.encode(data)),
        "execution": execution.toJSON()
    ]));
}

@endpoint @route!(matchesPath!"/api/acp/<id>/bind")
void bindAcp(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    Execution execution = bridge.execution(routeParameter!"/api/acp/<id>/bind"(request));
    if (execution is null || execution.kind != ExecutionKind.Acp || !execution.running)
        throw new InvalidInputException("Unknown active ACP execution");

    string session = readField!"sessionId"(request);
    Session.validateId(session);
    execution.identify(session);
    bridge.access.remember(session, execution.trusted);
    bridge.session(session).bindExecution(execution);
    if (!profileStore.assigned(session))
        profileStore.register(execution.profileName, session);

    respond(output, execution.toJSON());
}

class Devin : Bridge
{
public:
    const string sessionLockDir;
    const string sessionDatabase;
    const string compactionThresholds;

    this(Config configuration)
    {
        super(configuration.devinCommand, buildPath(configuration.dataDir, "sessions"), SCRUB_PREFIXES);
        sessionLockDir = configuration.sessionLockDir;
        sessionDatabase = configuration.sessionDatabase;
        compactionThresholds = configuration.compactionThresholds;
        executionTimeout = configuration.executionTimeout;
        collect();
    }

    static string[] arguments(string prompt, string model = null)
    {
        if (!prompt.length || prompt.canFind('\0'))
            throw new InvalidInputException("A prompt is required");
        if (model.canFind('\0'))
            throw new InvalidInputException("Invalid model name");

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
        if (result != 0 && errno != EWOULDBLOCK)
            throw new ErrnoException("Could not inspect session lock");

        return result != 0;
    }

    SessionMetadata sessionMetadata(string id)
    {
        Session.validateId(id);
        try
            return readSessionMetadata(sessionDatabase, id);
        catch (Exception)
            return SessionMetadata.init;
    }

    override Execution remove(string id)
    {
        Session session = this.session(id);
        if (session.isRunning() && session.execution.kind == ExecutionKind.Remove)
            return session.execution;
        if (!session.isRunning() && online(id))
            throw new ConflictException("Cannot remove a session owned by another process");

        Execution ret = newExecution(ExecutionKind.Remove, null, null, session.id);
        launch(ret, ["rm", "--force", "--", session.id], session.execution);
        session.bindExecution(ret);
        return ret;
    }

    Execution resume(
        string id,
        string prompt,
        string directory,
        string model,
        Execution dependency = null,
        string mode = null
    )
    {
        Execution ret = submit(ExecutionKind.Resume, prompt, directory, model, id, dependency, null, mode);
        session(id).bindExecution(ret);
        return ret;
    }

    Execution compact(string id, string directory, string model = null)
        => submit(
            ExecutionKind.Compact,
            COMPACT_PROMPT,
            directory,
            model,
            id,
            null,
            [COMPACTION_THRESHOLDS_ENV: compactionThresholds]
        );

    Execution start(
        string prompt,
        string directory,
        string model = null,
        string mode = null,
        bool trusted = false,
        string profileName = null
    )
        => submit(ExecutionKind.Start, prompt, directory, model, null, null, null, mode, trusted, profileName);

    Execution print(string prompt, string directory, string model = null)
        => submit(ExecutionKind.Print, prompt, directory, model);

    Execution acp(string directory, string model, string id = null)
    {
        if (!directory.length || !exists(directory) || !isDir(directory) || model.canFind('\0'))
            throw new InvalidInputException("Invalid ACP working directory or model");
        if (id.length && (!access.managed(id) || session(id).isRunning() || online(id)))
            throw new ConflictException("ACP session is unmanaged or already active");

        Execution ret = newExecution(ExecutionKind.Acp, directory, model, id);
        ret.trusted = id.length && access.trusted(id);
        ret.profileName = "autonom-"~ret.id[0..8];
        launch(ret, model.length ? ["acp", "--model", model] : ["acp"]);
        if (id.length)
            session(id).bindExecution(ret);

        return ret;
    }

    string[] list(string directory = null)
    {
        JSONValue data;
        try
            data = parseJSON(run(["list", "--format", "json"], directory));
        catch (Exception)
            throw new BackendException("Could not list backend sessions");

        if (data.type != JSONType.array)
            throw new BackendException("Invalid backend session list");

        string[] ret;
        foreach (entry; data.array)
        {
            if (entry.type != JSONType.object || "id" !in entry.object || entry["id"].type != JSONType.string)
                throw new BackendException("Invalid backend session list");

            Session.validateId(entry["id"].str);
            ret ~= session(entry["id"].str).id;
        }

        return ret;
    }

protected:
    override Session createSession(string id)
        => new DevinSession(id, this);

private:
    enum COMPACT_PROMPT = "Reply with exactly: OK";
    enum COMPACTION_THRESHOLDS_ENV = "DEVIN_COMPACTION_THRESHOLDS";

    string lockPath(string id) const
        => buildPath(sessionLockDir, id~".lock");

    Execution submit(
        ExecutionKind kind,
        string prompt,
        string directory,
        string model,
        string id = null,
        Execution dependency = null,
        string[string] environment = null,
        string mode = null,
        bool trusted = false,
        string profileName = null
    )
    {
        if (!directory.length || !exists(directory) || !isDir(directory))
            throw new InvalidInputException("An existing working directory is required");

        if (id.length)
        {
            SessionMetadata metadata = sessionMetadata(id);
            if (!model.length)
                model = metadata.model;
            if (!mode.length)
                mode = metadata.mode;

            trusted = access.trusted(id);
        }

        string permission = mode == "bypass" ? "dangerous" : mode == "ask" ? "auto" : mode;
        if (permission.length && !["auto", "normal", "accept-edits", "smart", "dangerous", "autonomous"]
            .canFind(permission))
            throw new InvalidInputException("Invalid permission mode");

        string[] args = arguments(prompt, model);
        Execution ret = newExecution(kind, directory, model, id);
        ret.mode = mode.idup;
        ret.trusted = trusted;
        ret.profileName = profileName.idup;
        string[] options = ["--export", ret.exportPath];
        if (permission.length)
            options ~= ["--permission-mode", permission];
        if (trusted)
            options ~= ["--respect-workspace-trust", "false"];

        args = args[0..$-2]~options~args[$-2..$];
        if (id.length)
            args = ["--resume", id]~args;

        return launch(ret, args, null, dependency, environment);
    }
}
