module daemon.interop.devin.bridge;

import daemon.agent : Profile, validName;
static import daemon.api;
import daemon.http;
import daemon.config : DaemonConfig = Config;
import daemon.exception;
import daemon.interop.devin.acp;
import daemon.interop.devin.db;
import daemon.interop.metadata : SessionMetadata;
import daemon.interop.acp : AcpClient, AcpException;
import daemon.interop.access;
import daemon.interop.devin.process : removeSession;
import daemon.interop.process;
import daemon.interop.session : SessionBase = Session;
import daemon.interop.devin.session : Session;
import daemon.interop.provider : IProvider;
import daemon.interop.call;
import daemon.storage;

import serverino;

import core.stdc.errno : errno, EWOULDBLOCK;
import core.sync.mutex : Mutex;
import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB;
import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDONLY, O_RDWR;
import core.sys.posix.signal : SIGKILL, SIGTERM;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : canFind, endsWith, sort;
import std.array : join;
import std.conv : octal, to;
import std.datetime : Clock, UTC;
import std.exception : ErrnoException;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : baseName, buildPath, dirName;
import std.process;
import std.stdio : File;
import std.uuid;

class Bridge : IProvider
{
private:
    struct Observed
    {
        string connection;
        string directory;
        bool active;
    }

    Access _access;
    Session[string] sessions;
    Call[string] executions;
    bool[string] removed;
    Observed[string] observed;
    MonoTime[string] connections;

    JSONValue[string] executionRecords;
    string[] executionOrder;
    enum maxIndexedExecutions = 10_000;

    string executionIndexPath() const
        => buildPath(executionDir, "index.json");

    void loadExecutionIndex()
    {
        string path = executionIndexPath();
        if (!exists(path))
            return;

        try
        {
            JSONValue data = readJSON(path, 10 * 1024 * 1024);
            if (data.type != JSONType.object)
                return;

            if ("executions" in data.object && data["executions"].type == JSONType.object)
            {
                foreach (id, item; data["executions"].object)
                {
                    if (item.type != JSONType.object)
                        continue;

                    JSONValue record = JSONValue.emptyObject;
                    record["id"] = JSONValue(id.idup);
                    foreach (field; ["sessionId", "createdAt", "finishedAt", "status", "model", "workspace", "mode"])
                    {
                        record[field] = field in item.object && item[field].type == JSONType.string
                            ? JSONValue(item[field].str.idup)
                            : JSONValue(null);
                    }

                    executionRecords[id.idup] = record;
                    executionOrder ~= id.idup;
                }
            }

            executionOrder.sort!((left, right) {
                string leftTime = executionRecords[left]["createdAt"].isNull ? "" : executionRecords[left]["createdAt"].str;
                string rightTime = executionRecords[right]["createdAt"].isNull ? "" : executionRecords[right]["createdAt"].str;
                return leftTime == rightTime ? left < right : leftTime < rightTime;
            });
            while (executionOrder.length > maxIndexedExecutions)
            {
                executionRecords.remove(executionOrder[0]);
                executionOrder = executionOrder[1..$];
            }
        }
        catch (Exception)
        {
            // Transcript files remain available if the optional lookup index is damaged.
            executionRecords = null;
            executionOrder = null;
        }
    }

    void saveExecutionIndex()
    {
        try
        {
            mkdirRecurse(executionDir);
            JSONValue data = JSONValue.emptyObject;
            data["version"] = JSONValue(1);
            JSONValue execs = JSONValue.emptyObject;
            foreach (id, rec; executionRecords)
                execs[id] = rec;
            data["executions"] = execs;
            atomicWrite(executionIndexPath(), data.toString());
        }
        catch (Exception)
        {
        }
    }

    void recordExecution(Call call)
    {
        JSONValue data = call.toJSON();
        JSONValue record = JSONValue.emptyObject;
        foreach (field; ["id", "sessionId", "createdAt", "finishedAt", "status", "model", "workspace", "mode"])
            record[field] = data[field];

        if (call.id !in executionRecords)
        {
            if (executionOrder.length >= maxIndexedExecutions)
            {
                string oldest = executionOrder[0];
                executionOrder = executionOrder[1..$];
                executionRecords.remove(oldest);
            }
            executionOrder ~= call.id;
        }
        executionRecords[call.id] = record;
        saveExecutionIndex();
    }

    void dropObserved(string id)
    {
        observed.remove(id);
        access.revokeMcp(id);
    }

    void checkCapacity()
    {
        size_t active;
        foreach (entry; executions)
            active += entry.running;

        if (active >= maxConcurrentCalls)
            throw new ConflictException("Call capacity reached");
    }

    void launch(Call call, string prompt = null, bool compactFirst = false,
        Call previous = null, string connection = null)
    {
        checkCapacity();
        string runToken = access.begin(call);
        executions[call.id] = call;
        recordExecution(call);
        call._timeout = call.kind == CallKind.Remove ? 10.seconds : executionTimeout;
        call.deadline = MonoTime.currTime + call.timeout;
        call.monitor = new Thread({
            CallResult result;
            try
            {
                if (call.kind == CallKind.Remove)
                {
                    if (previous !is null)
                        previous.stop();
                    if (call.stopped)
                        result.cancelled = true;
                    else
                        result = removeSession(command, call);
                }
                else if (connection.length)
                {
                    result = runControl(call, controlSocket(connection), access.clientToken,
                        call.sessionId, prompt, call.model, normalizeMode(call.mode));
                }
                else if (call.stopped)
                    result.cancelled = true;
                else
                {
                    result = runAcp(call, command, call.workspace, call.sessionId, prompt,
                        call.model, call.mode, runToken, mcpPort, dataDir, access, compactFirst);
                }
            }
            catch (Exception error)
                result.error = error.msg.idup;
            call.finish(result);
        });
        call.monitor.start();
    }

public:

    Duration executionTimeout = 30 * 60.seconds;
    size_t callCapacity = 128;
    Duration callSettleTimeout = 300.seconds;
    size_t maxConcurrentCalls = 8;
    const string command;
    const string logDir;
    const string executionDir;

    this(DaemonConfig configuration)
    {
        command = configuration.devinCommand;
        logDir = buildPath(configuration.dataDir, "sessions");
        sessionLockDir = configuration.sessionLockDir;
        sessionDatabase = configuration.sessionDatabase;
        dataDir = configuration.dataDir;
        mcpPort = environment.get("AUTONOM_PORT", "8080");
        executionTimeout = configuration.executionTimeout;
        callCapacity = configuration.callCapacity;
        callSettleTimeout = configuration.callSettleTimeout;
        maxConcurrentCalls = configuration.maxConcurrentCalls;
        controlMutex = new Mutex();
        _access = new Access(dirName(logDir));
        executionDir = buildPath(dirName(logDir), "executions");
        if ((exists(logDir) && isSymlink(logDir)) ||
            (exists(executionDir) && isSymlink(executionDir)))
            throw new Exception("Backend storage must not be a symlink");

        loadExecutionIndex();
        collect();
    }

    string sessionForExecution(string id)
    {
        if (Call* call = id in executions)
        {
            if ((*call).sessionId.length)
                return (*call).sessionId;
        }
        if (JSONValue* record = id in executionRecords)
            return (*record)["sessionId"].isNull ? null : (*record)["sessionId"].str;

        return null;
    }

    JSONValue executionRecord(string id)
    {
        if (Call* call = id in executions)
            return (*call).toJSON();

        if (JSONValue* record = id in executionRecords)
            return *record;

        return JSONValue(null);
    }

    size_t executionCount() const
        => executions.length;

    private Call newCall(
        CallKind kind,
        string directory,
        string model,
        string sessionId = null
    )
    {
        return new Call(
            executionDir,
            logDir,
            randomUUID().toString(),
            kind,
            directory,
            model,
            sessionId
        );
    }

    override Access access()
        => _access;

    override Session session(string id)
    {
        Session.validateId(id);
        return resolve(id, sessionMetadata(id));
    }

    override Session findSession(string id)
    {
        Session.validateId(id);
        if (id in removed)
            return null;

        SessionMetadata data = sessionMetadata(id);
        if (data.id.length || observedSession(id))
        {
            return resolve(id, data);
        }
        if (Session* found = id in sessions)
        {
            if ((*found).isRunning())
                return *found;
        }

        return null;
    }

    override SessionBase[] list(string directory = null, string acp = null)
    {
        SessionBase[] ret;
        bool[string] listed;
        foreach (call; executions)
        {
            string id = call.sessionId;
            if (!call.running || !id.length || id in removed)
                continue;

            if (id !in sessions)
                sessions[id] = new Session(id, this);

            Session entry = sessions[id];
            if (entry.execution is null || entry.execution.createdAt <= call.createdAt)
                entry.bindCall(call);
        }

        foreach (data; readSessionCatalog(sessionDatabase))
        {
            Session.validateId(data.id);
            if (data.id in removed)
                continue;

            Session entry = resolve(data.id, data);
            listed[entry.id] = true;
            if ((!directory.length || data.directory == directory) &&
                (!acp.length || data.acp == acp))
                ret ~= entry;
        }
        foreach (id, observedEntry; observed)
        {
            if (id !in sessions)
                sessions[id] = new Session(id, this);
        }
        foreach (id, entry; sessions)
        {
            if (id !in listed)
            {
                entry.updateMetadata(SessionMetadata.init);
                if (id !in removed && (entry.isRunning() || observedSession(id)) &&
                    (!directory.length || entry.workspace == directory) &&
                    (!acp.length || entry.metadata.acp == acp))
                {
                    ret ~= entry;
                }
            }
        }

        return ret;
    }

    override Call execution(string id)
    {
        Session.validateId(id);
        Call* found = id in executions;
        return found is null ? null : *found;
    }

    JSONValue pendingPermissions(string id, long requestId = 0)
    {
        if (observedSession(id))
            return controlRequest(controlSocket(observedConnection(id)), access.clientToken,
                "autonom/permissions", JSONValue([
                    "sessionId": JSONValue(id), "id": JSONValue(requestId)
                ]), null, 250.msecs);
        foreach (execution; executions)
        {
            if (execution.running && execution.sessionId == id && execution.connection !is null)
                return execution.connection.permissions(id, requestId);
        }
        return JSONValue.emptyArray;
    }

    void decidePermission(string id, long requestId, string option)
    {
        try
        {
            if (observedSession(id))
            {
                controlRequest(controlSocket(observedConnection(id)), access.clientToken,
                    "autonom/permission", JSONValue([
                        "sessionId": JSONValue(id), "id": JSONValue(requestId),
                        "optionId": option.length ? JSONValue(option) : JSONValue(null)
                    ]), null, 250.msecs);
                return;
            }
            foreach (execution; executions)
            {
                if (execution.running && execution.sessionId == id && execution.connection !is null)
                {
                    execution.connection.decide(id, requestId, option);
                    return;
                }
            }
            throw new ConflictException("Permission request is no longer pending");
        }
        catch (AcpException error)
        {
            if (error.code == -32602)
                throw new InvalidInputException(error.msg);
            throw new ConflictException(error.msg);
        }
    }

    override bool isRemoved(string id)
        => (id in removed) !is null;

    bool observedSession(string id)
        => (id in observed) !is null;

    bool observedActive(string id)
    {
        Observed* found = id in observed;
        return found !is null && found.active;
    }

    string observedConnection(string id)
    {
        Observed* found = id in observed;
        return found is null ? null : found.connection;
    }

    string observedDirectory(string id)
    {
        Observed* found = id in observed;
        return found is null ? null : found.directory;
    }

    void observeConnection(string connection, string[] ids, string[string] directories,
        bool[string] active, bool closed)
    {
        try
            UUID(connection);
        catch (Exception)
            throw new InvalidInputException("Invalid connection ID");

        if (closed)
        {
            connections.remove(connection);
            foreach (id; observed.keys)
            {
                if (observed[id].connection == connection)
                    dropObserved(id);
            }
            return;
        }

        connections[connection.idup] = MonoTime.currTime;
        bool[string] listed;
        foreach (id; ids)
        {
            Session.validateId(id);
            observed[id.idup] = Observed(
                connection.idup,
                directories.get(id, null),
                active.get(id, false)
            );
            listed[id.idup] = true;
        }
        foreach (id; observed.keys)
        {
            if (observed[id].connection == connection && id !in listed)
                dropObserved(id);
        }
    }

    void admitObserved(string connection, string id, string directory)
    {
        Session.validateId(id);
        connections[connection.idup] = MonoTime.currTime;
        Observed* found = id in observed;
        observed[id.idup] = Observed(
            connection.idup,
            directory.length ? directory :
                found !is null && found.connection == connection ? found.directory : null,
            found !is null && found.connection == connection && found.active
        );
    }

    void sweepObserved()
    {
        MonoTime cutoff = MonoTime.currTime - 30.seconds;
        foreach (connection; connections.keys)
        {
            if (connections[connection] < cutoff)
                connections.remove(connection);
        }

        foreach (id; observed.keys)
        {
            if (observed[id].connection !in connections)
                dropObserved(id);
        }
    }

    override Call[] listCalls(string directory = null)
    {
        Call[] ret;
        foreach (execution; executions)
        {
            if (!directory.length || execution.workspace == directory)
                ret ~= execution;
        }

        ret.sort!((left, right) => left.createdAt < right.createdAt);
        return ret;
    }

    override Call authenticate(string token, string id, bool bind = false)
    {
        Call ret = access.authenticate(token, id, bind);
        if (ret !is null)
            session(id).bindCall(ret);

        return ret;
    }

    override string[] collect()
    {
        sweepObserved();
        Call[] ready;
        foreach (execution; executions)
        {
            if (!execution.running && !execution.collected)
                ready ~= execution;
        }

        ready.sort!((left, right)
        {
            return left.createdAt < right.createdAt;
        });
        foreach (execution; ready)
        {
            execution.wait();
            string id = execution.sessionId;
            if (id.length)
            {
                if (execution.kind == CallKind.Remove && execution.status == CallStatus.Succeeded)
                {
                    removeLog(id);
                    sessions.remove(id);
                    access.forget(id);
                    removed[id] = true;
                }
                else if (id !in removed)
                {
                    if (execution.kind == CallKind.Start || execution.kind == CallKind.Print)
                        access.remember(id, execution.trusted);

                    Session session = this.session(id);
                    if (session.execution is null || session.execution.createdAt <= execution.createdAt)
                        session.bindCall(execution);
                }
            }

            execution.collected = true;
        }

        Call[] settledCalls;
        foreach (call; executions.byValue)
        {
            if (!call.running)
                settledCalls ~= call;
        }

        settledCalls.sort!((left, right)
        {
            if (left.settled != right.settled)
                return left.settled < right.settled;
            if (left.createdAt != right.createdAt)
                return left.createdAt < right.createdAt;
            return left.id < right.id;
        });

        MonoTime now = MonoTime.currTime;
        foreach (call; settledCalls)
        {
            bool expired = (now - call.settled > callSettleTimeout);
            bool overCapacity = (executions.length > callCapacity);
            if (expired || overCapacity)
            {
                recordExecution(call);
                executions.remove(call.id);
            }
            else
            {
                break;
            }
        }
        access.collect();
        return removed.keys;
    }

    override void stopSessions()
    {
        foreach (execution; executions)
            execution.requestStop();
    }

    override void close()
    {
        Exception failure;
        foreach (execution; executions)
        {
            try
                execution.requestStop();
            catch (Exception error)
            {
                if (failure is null)
                    failure = error;
            }
        }

        foreach (execution; executions)
        {
            try
                execution.wait();
            catch (Exception error)
            {
                if (failure is null)
                    failure = error;
            }
        }

        if (failure !is null)
            throw failure;
    }

    string logPath(string id) const
        => buildPath(logDir, id~".log");

    void removeLog(string id)
    {
        Session.validateId(id);
        string path = logPath(id);
        if (exists(path))
            std.file.remove(path);
    }

    const string sessionLockDir;
    const string sessionDatabase;
    const string dataDir;
    const string mcpPort;

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

    override SessionMetadata sessionMetadata(string id)
    {
        Session.validateId(id);
        SessionMetadata ret = readSessionMetadata(sessionDatabase, id);

        if (!ret.id.length)
            ret.directory = observedDirectory(id);

        return ret;
    }

    Call remove(string id)
    {
        Session session = this.session(id);
        if (session.isRunning() && session.execution.kind == CallKind.Remove)
            return session.execution;
        if (observedSession(id) || (!session.isRunning() && online(id)))
            throw new ConflictException("Cannot remove a session owned by another process");

        Call ret = newCall(CallKind.Remove, null, null, session.id);
        launch(ret, null, false, session.execution);
        session.bindCall(ret);
        return ret;
    }

    override Call resume(
        string id,
        string prompt,
        string directory,
        string model,
        bool compactFirst = false,
        string mode = null
    )
    {
        Call ret = submit(CallKind.Resume, prompt, directory, model, id, compactFirst, mode);
        session(id).bindCall(ret);
        return ret;
    }

    Call resumeObserved(
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

        Call ret = newCall(CallKind.Resume, directory, model, id);
        ret.mode = mode.idup;
        launch(ret, prompt, false, null, connection);
        session(id).bindCall(ret);
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

    Call steerObserved(string id, string prompt)
    {
        if (!prompt.length || prompt.canFind('\0'))
            throw new InvalidInputException("A prompt is required");

        string connection = observedConnection(id);
        if (!connection.length)
            throw new ConflictException("Observed session is no longer connected");

        Call ret = newCall(CallKind.Resume, observedDirectory(id), null, id);
        launch(ret, prompt, false, null, connection);
        session(id).bindCall(ret);
        return ret;
    }

    override Call start(
        string prompt,
        string directory,
        string model = null,
        string mode = null,
        bool trusted = false,
        string profileName = null
    )
        => submit(CallKind.Start, prompt, directory, model, null, false, mode, trusted, profileName);

    Call print(string prompt, string directory, string model = null)
        => submit(CallKind.Print, prompt, directory, model);

    Call steer(string id, string prompt)
    {
        if (!prompt.length || prompt.canFind('\0'))
            throw new InvalidInputException("A prompt is required");

        Session bound = session(id);
        Call active = bound.execution;
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

private:
    Session resolve(string id, SessionMetadata data)
    {
        Session ret;
        if (Session* found = id in sessions)
            ret = *found;
        else
        {
            ret = new Session(id, this);
            sessions[ret.id] = ret;
        }
        ret.updateMetadata(data);
        return ret;
    }

    Mutex controlMutex;
    bool[string] cancelling;

    string lockPath(string id) const
        => buildPath(sessionLockDir, id~".lock");

    string controlSocket(string connection) const
        => buildPath(dataDir, "acp", connection~".sock");

    Call submit(
        CallKind kind,
        string prompt,
        string directory,
        string model,
        string id = null,
        bool compactFirst = false,
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

        Call ret = newCall(kind, directory, model, id);
        ret.mode = mode.idup;
        ret.trusted = trusted;
        ret.profileName = profileName.idup;
        launch(ret, prompt, compactFirst);
        return ret;
    }
}

@endpoint @route!"/api/print"
void printSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    Launch launch = readLaunch(request);
    respond(output, daemon.api.bridge.print(launch.prompt, launch.directory, launch.model).toJSON(), 202);
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

    daemon.api.bridge.observeConnection(data["connection"].str, ids, directories, active, data["closed"].boolean);
    respond(output, JSONValue(["ok": JSONValue(true)]));
}


@endpoint @route!"/api/acp/admit"
void admit(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readBody(request);
    onlyFields(data, ["connection", "session", "token", "directory"]);
    foreach (required; ["connection", "session", "token"])
    {
        if (required !in data.object || data[required].type != JSONType.string)
            throw new InvalidInputException("Expected string connection, session, and token");
    }
    try
        UUID(data["connection"].str);
    catch (Exception)
        throw new InvalidInputException("Invalid connection ID");
    if (data["token"].str.length != 64)
        throw new InvalidInputException("Invalid MCP credential");
    foreach (character; data["token"].str)
    {
        if (!(character >= '0' && character <= '9') && !(character >= 'a' && character <= 'f'))
            throw new InvalidInputException("Invalid MCP credential");
    }
    if ("directory" in data.object &&
        (data["directory"].type != JSONType.string || data["directory"].str.canFind('\0')))
        throw new InvalidInputException("Invalid directory");

    daemon.api.bridge.admitObserved(data["connection"].str, data["session"].str,
        "directory" in data.object ? data["directory"].str : null);
    if (!daemon.api.bridge.access.admitMcp(data["token"].str, data["session"].str))
        throw new ConflictException("MCP credential is already bound to another session");

    daemon.api.bridge.access.remember(data["session"].str);

    respond(output, JSONValue(["session": data["session"]]));
}
