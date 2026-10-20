module daemon.interop.devin.bridge;

import daemon.config : DaemonConfig = Config;
import daemon.exception;
import daemon.interop.access : Access;
import daemon.interop.acp : AcpDisconnectedException;
import daemon.interop.call;
import daemon.interop.devin.acp : runAcp;
import daemon.interop.devin.calls;
import daemon.interop.devin.connection;
import daemon.interop.devin.control : runControl;
import daemon.interop.devin.catalog : Catalog;
import daemon.interop.devin.history : loadExecutionIndex, recordExecution;
static import daemon.interop.devin.history;
import daemon.interop.devin.options : normalizeMode;
import daemon.interop.devin.process : removeSession;
import daemon.interop.devin.prompt : DeliveryDeferredException;
import daemon.interop.devin.session : Session;
import daemon.interop.devin.session.catalog;
import daemon.interop.devin.session.control : resumeObserved;
import daemon.interop.session : TurnStatus;
import daemon.interop.metadata : SessionMetadata;
import daemon.interop.provider : IProvider;
import daemon.interop.session : SessionBase = Session;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, seconds;
import std.algorithm : canFind;
import std.file : exists, isDir, isSymlink;
import std.json : JSONValue;
import std.path : buildPath, dirName;
import std.process : environment;

class Bridge : IProvider
{
package(daemon.interop.devin):
    struct Observed
    {
        string connection;
        string directory;
    }

    Catalog catalog;
    const string dataDir;
    const string mcpPort;
    Mutex controlMutex;
    bool[string] cancelling;
    Access _access;
    Session[string] sessions;
    Call[string] executions;
    bool[string] removed;
    Observed[string] observed;
    MonoTime[string] connections;

    JSONValue[string] executionRecords;
    string[] executionOrder;
    enum maxIndexedExecutions = 10_000;

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
        catalog = new Catalog(buildPath(configuration.dataDir, "cli", "sessions.db"),
            configuration.sessionDatabase, configuration.sessionLockDir);
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

        this.loadExecutionIndex();
        collect();
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
        if (data.id.length || this.observedSession(id))
            return resolve(id, data);
        if (Session* found = id in sessions)
        {
            if ((*found).hasActiveCall())
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
            if (!call.automatic && (entry.execution is null || entry.execution.createdAt <= call.createdAt))
                entry.bindCall(call);
        }

        foreach (data; catalog.list())
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
        foreach (id, instance; observed)
        {
            if (id !in sessions)
                sessions[id] = new Session(id, this);
        }
        foreach (id, entry; sessions)
        {
            if (id !in listed)
            {
                entry.updateMetadata(SessionMetadata.init);
                if (id !in removed && (entry.hasActiveCall() || this.observedSession(id)) &&
                    (!directory.length || entry.workspace == directory) &&
                    (!acp.length || entry.metadata.acp == acp))
                    ret ~= entry;
            }
        }

        return ret;
    }

    override Call execution(string id)
        => findCall(this, id);

    override JSONValue executionRecord(string id)
        => daemon.interop.devin.history.executionRecord(this, id);

    override bool isRemoved(string id)
        => (id in removed) !is null;

    override Call[] listCalls(string directory = null)
        => daemon.interop.devin.calls.listCalls(this, directory);

    override Call authenticate(string token, string id, bool bind = false)
    {
        Call ret = access.authenticate(token, id, bind);
        if (ret !is null)
            session(id).bindCall(ret);

        return ret;
    }

    override string[] collect()
        => collectCalls(this);

    override void stopSessions()
    {
        stopCalls(this);
    }

    override void close()
    {
        closeCalls(this);
    }

    override bool online(string id)
        => daemon.interop.devin.session.catalog.online(this, id);

    override SessionMetadata sessionMetadata(string id)
        => daemon.interop.devin.session.catalog.sessionMetadata(this, id);

    override Call resume(
        string id,
        string prompt,
        string directory,
        string model,
        bool compactFirst = false,
        string mode = null
    )
    {
        Session bound = session(id);
        if (bound.hasActiveCall())
            throw new ConflictException("Session is already active");
        if (this.observedSession(id))
        {
            if (bound.activity != TurnStatus.Idle)
                throw new ConflictException("Session is not idle");

            return this.resumeObserved(id, prompt, directory, model, mode);
        }
        if (online(id))
            throw new ConflictException("Session is loaded by another process");

        Call ret = submit(CallKind.Resume, prompt, directory, model, id, compactFirst, mode);
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

package(daemon.interop.devin):
    void launch(Call call, string prompt = null, bool compactFirst = false,
        Call previous = null, string connection = null, bool automatic = false)
    {
        this.checkCapacity();
        string database = catalog.databaseFor(call.sessionId);
        call.automatic = automatic;
        string runToken = access.begin(call);
        executions[call.id] = call;
        this.recordExecution(call);
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
                        result = removeSession(command, call, database);
                }
                else if (connection.length)
                {
                    result = runControl(call, this.controlSocket(connection), access.clientToken,
                        call.sessionId, prompt, call.model, normalizeMode(call.mode), automatic);
                }
                else if (call.stopped)
                    result.cancelled = true;
                else
                {
                    result = runAcp(call, command, call.workspace, call.sessionId, prompt,
                        call.model, call.mode, runToken, mcpPort, dataDir, access, compactFirst, database);
                }
            }
            catch (DeliveryDeferredException)
                result.deferred = true;
            catch (AcpDisconnectedException error)
            {
                result.interrupted = true;
                result.error = error.msg.idup;
            }
            catch (Exception error)
                result.error = error.msg.idup;
            call.finish(result);
        });
        call.monitor.start();
    }
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

        Call ret = this.newCall(kind, directory, model, id);
        ret.mode = mode.idup;
        ret.trusted = trusted;
        ret.profileName = profileName.idup;
        launch(ret, prompt, compactFirst);
        return ret;
    }
}
