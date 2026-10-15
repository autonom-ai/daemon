module daemon.interop.devin.bridge;

import daemon.agent : Profile, validName;
import daemon.config;
import daemon.exception;
import daemon.http;
import daemon.interop.bridge;
import daemon.interop.devin.acp;
import daemon.interop.devin.db : readSessionMetadata;
import daemon.interop.devin.session;
import daemon.interop.execution;
import daemon.storage;
import daemon.interop.metadata : SessionMetadata;
import daemon.interop.session;
import daemon.runtime : bridge, profileStore;
import serverino;

import core.stdc.errno : errno, EWOULDBLOCK;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB;
import core.sys.posix.fcntl : O_RDONLY;
import std.algorithm : canFind;
import std.exception : ErrnoException;
import std.file;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.stdio : File;
import std.string : toLower;
import std.uuid : UUID;

public:

@endpoint @route!"/api/sessions"
void sessions(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    if (request.method == Request.Method.Get)
        respond(output, JSONValue(bridge.sessionIds()));
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

@endpoint @route!"/api/acp/observe"
void observe(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readBody(request, 1024 * 1024);
    string[string] required = [
        "connection": "string",
        "sessions": "array",
        "closed": "boolean"
    ];
    foreach (name, value; data.object)
    {
        if (name !in required)
            throw new InvalidInputException("Invalid observation field");
    }
    foreach (name, type; required)
    {
        if (name !in data.object)
            throw new InvalidInputException("Missing observation field "~name);
        if ((type == "string" && data[name].type != JSONType.string) ||
            (type == "array" && data[name].type != JSONType.array) ||
            (type == "boolean" && data[name].type != JSONType.true_ &&
            data[name].type != JSONType.false_))
            throw new InvalidInputException("Invalid observation field "~name);
    }

    try
        UUID(data["connection"].str);
    catch (Exception)
        throw new InvalidInputException("Invalid connection ID");

    string[] ids;
    string[string] directories;
    bool[string] active;
    foreach (entry; data["sessions"].array)
    {
        if (entry.type != JSONType.object)
            throw new InvalidInputException("Invalid observed session");
        foreach (name, value; entry.object)
        {
            if (name != "id" && name != "directory" && name != "active")
                throw new InvalidInputException("Invalid observed session field");
            if ((name == "id" || name == "directory") && value.type != JSONType.string)
                throw new InvalidInputException("Invalid observed session field");
            if (name == "active" && value.type != JSONType.true_ && value.type != JSONType.false_)
                throw new InvalidInputException("Invalid observed session field");
        }
        if ("id" !in entry.object || "directory" !in entry.object || "active" !in entry.object)
            throw new InvalidInputException("Observed sessions require id, directory, and active");

        Session.validateId(entry["id"].str);
        if (entry["directory"].str.canFind('\0'))
            throw new InvalidInputException("Invalid observed directory");

        ids ~= entry["id"].str.idup;
        directories[entry["id"].str.idup] = entry["directory"].str.idup;
        active[entry["id"].str.idup] = entry["active"].boolean;
    }

    bridge.observeConnection(data["connection"].str, ids, directories, active, data["closed"].boolean);
    respond(output, JSONValue(["ok": JSONValue(true)]));
}

class Devin : Bridge
{
public:
    const string sessionLockDir;
    const string sessionDatabase;
    const string compactionThresholds;
    const string dataDir;

    this(Config configuration)
    {
        super(configuration.devinCommand, buildPath(configuration.dataDir, "sessions"));
        sessionLockDir = configuration.sessionLockDir;
        sessionDatabase = configuration.sessionDatabase;
        compactionThresholds = configuration.compactionThresholds;
        dataDir = configuration.dataDir;
        executionTimeout = configuration.executionTimeout;
        controlMutex = new Mutex();
        collect();
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
        SessionMetadata ret;
        try
            ret = readSessionMetadata(sessionDatabase, id);
        catch (Exception)
            ret = SessionMetadata.init;

        if (!ret.id.length && !ret.directory.length && observedDirectory(id).length)
        {
            ret.id = id;
            ret.directory = observedDirectory(id);
        }

        return ret;
    }

    override Execution remove(string id)
    {
        Session session = this.session(id);
        if (session.isRunning() && session.execution.kind == ExecutionKind.Remove)
            return session.execution;
        if (observedSession(id) || (!session.isRunning() && online(id)))
            throw new ConflictException("Cannot remove a session owned by another process");

        Execution ret = newExecution(ExecutionKind.Remove, null, null, session.id);
        launchProcess(ret, ["rm", "--force", "--", session.id], session.execution);
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

    Execution resumeObserved(
        string id,
        string prompt,
        string directory,
        string model,
        string mode
    )
    {
        if (!prompt.length || prompt.canFind('\0'))
            throw new InvalidInputException("A prompt is required");
        if (model.canFind('\0'))
            throw new InvalidInputException("Invalid model name");

        string connection = observedConnection(id);
        if (!connection.length)
            throw new ConflictException("Observed session is no longer connected");

        string observed = observedDirectory(id);
        if (directory.length && observed.length && directory != observed)
            throw new InvalidInputException("Directory does not match the observed session");
        if (!observed.length)
            throw new InvalidInputException("An existing working directory is required");
        directory = observed;

        Execution ret = newExecution(ExecutionKind.Resume, directory, model, id);
        ret.mode = mode.idup;
        launchTask(ret, controlTask(
            controlSocket(connection),
            access.clientToken,
            id,
            prompt,
            model,
            normalizeMode(mode)
        ));
        session(id).bindExecution(ret);
        return ret;
    }

    void cancelObserved(string id)
    {
        string connection = observedConnection(id);
        if (!connection.length)
            throw new ConflictException("Observed session is no longer connected");

        string socketPath = controlSocket(connection);
        string token = access.clientToken;
        synchronized (controlMutex)
        {
            if (id in cancelling || cancelling.length >= 8)
                return;

            cancelling[id] = true;
        }
        (new Thread({
            try
                controlRequest(socketPath, token, "session/cancel",
                    JSONValue(["sessionId": JSONValue(id)]));
            catch (Exception)
            {
            }
            synchronized (controlMutex)
                cancelling.remove(id);
        })).start();
    }

    Execution steerObserved(string id, string prompt)
    {
        if (!prompt.length || prompt.canFind('\0'))
            throw new InvalidInputException("A prompt is required");

        string connection = observedConnection(id);
        if (!connection.length)
            throw new ConflictException("Observed session is no longer connected");

        Execution ret = newExecution(ExecutionKind.Resume, observedDirectory(id), null, id);
        launchTask(ret, controlTask(controlSocket(connection), access.clientToken, id, prompt, null, null));
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

    Execution steer(string id, string prompt)
    {
        if (!prompt.length || prompt.canFind('\0'))
            throw new InvalidInputException("A prompt is required");

        Session bound = session(id);
        Execution active = bound.execution;
        if (active !is null && active.running && active.acceptingSteer)
        {
            if (!active.enqueueSteer(prompt))
                throw new ConflictException("Steering capacity reached");

            return active;
        }
        if (observedSession(id))
            return steerObserved(id, prompt);

        throw new BackendException("Session does not support steering");
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

    Mutex controlMutex;
    bool[string] cancelling;

    string lockPath(string id) const
        => buildPath(sessionLockDir, id~".lock");

    string controlSocket(string connection) const
        => buildPath(dataDir, "acp", connection~".sock");

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
        if (!prompt.length || prompt.canFind('\0'))
            throw new InvalidInputException("A prompt is required");
        if (model.canFind('\0'))
            throw new InvalidInputException("Invalid model name");
        if (!directory.length || !exists(directory) || !isDir(directory))
            throw new InvalidInputException("An existing working directory is required");

        normalizeMode(mode);
        if (id.length)
        {
            SessionMetadata metadata = sessionMetadata(id);
            if (!model.length)
                model = metadata.model;
            if (!mode.length)
                mode = metadata.mode;

            trusted = access.trusted(id);
        }

        Execution ret = newExecution(kind, directory, model, id);
        ret.mode = mode.idup;
        ret.trusted = trusted;
        ret.profileName = profileName.idup;
        string runToken = access.begin(ret);
        return launchTask(ret, acpTask(
            command,
            directory,
            id,
            prompt,
            model,
            mode,
            environment,
            runToken
        ), null, dependency);
    }
}
