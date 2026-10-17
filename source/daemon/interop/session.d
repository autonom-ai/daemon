module daemon.interop.session;

import daemon.exception;
import daemon.interop.bridge;
import daemon.interop.metadata : SessionMetadata;

import std.ascii;
import std.json : JSONValue;
import std.typecons : Nullable;

public:

enum SessionStatus : string
{
    Offline = "offline",
    Starting = "starting",
    Online = "online",
    Loaded = "loaded",
    Stopping = "stopping",
    Failed = "failed"
}

class Session
{
private:
    Call _execution;
    Bridge bridge;
    SessionMetadata _metadata;

package(daemon.interop):
    void updateMetadata(SessionMetadata data)
    {
        _metadata = data;
    }

    void bindCall(Call execution)
    {
        _execution = execution;
    }

public:
    const string id;

    static void validateId(string id)
    {
        if (!id.length || id.length > 128 || !isAlphaNum(id[0]))
            throw new InvalidInputException("Invalid session ID");

        foreach (character; id)
        {
            if (!isAlphaNum(character) && character != '-' && character != '_')
                throw new InvalidInputException("Invalid session ID");
        }
    }

    this(string id, Bridge bridge)
    {
        validateId(id);
        this.id = id.idup;
        this.bridge = bridge;
    }

    Call execution()
        => _execution;

    string model()
        => metadata.model;

    string title()
        => metadata.title;

    string mode()
        => metadata.mode;

    string workspace()
        => metadata.directory;

    bool isRunning()
        => _execution !is null && _execution.running;

    void stop()
    {
        requestStop();
        if (_execution !is null)
            _execution.wait();
    }

    Nullable!int exitStatus()
    {
        if (_execution is null || _execution.exitStatus.isNull)
            return Nullable!int.init;

        return Nullable!int(cast(int)_execution.exitStatus.integer);
    }

    JSONValue toJSON(bool refresh = true)
    {
        if (refresh)
            _metadata = bridge.sessionMetadata(id);

        SessionMetadata data = metadata;

        JSONValue ret = data.toJSON();
        ret["id"] = JSONValue(id);
        ret["status"] = JSONValue(cast(string)status);
        ret["exitStatus"] = exitStatus.isNull ? JSONValue(null) : JSONValue(exitStatus.get);
        ret["executionId"] = _execution is null ? JSONValue(null) : JSONValue(_execution.id);
        return ret;
    }

    SessionMetadata metadata()
    {
        SessionMetadata ret = _metadata;
        if (!ret.id.length)
        {
            if (_execution !is null)
            {
                ret.model = _execution.model;
                ret.mode = _execution.mode;
                ret.directory = _execution.workspace;
            }
            else
                ret.directory = bridge.observedDirectory(id);

            if (isRunning() || bridge.observedSession(id))
                ret.acp = "autonom";
        }

        return ret;
    }

    SessionStatus status()
    {
        if (execution !is null && execution.status == CallStatus.Stopping)
            return SessionStatus.Stopping;

        if (isRunning())
            return bridge.online(id) ? SessionStatus.Online : SessionStatus.Starting;
        if (bridge.observedActive(id))
            return SessionStatus.Online;
        if (bridge.online(id))
            return SessionStatus.Loaded;

        if (execution !is null && (execution.status == CallStatus.Failed ||
            execution.status == CallStatus.Interrupted))
            return SessionStatus.Failed;

        return SessionStatus.Offline;
    }

    void resume(
        string prompt,
        string directory,
        string model = null,
        string mode = null
    )
    {
        if (bridge.observedSession(id))
        {
            if (bridge.observedActive(id))
                throw new ConflictException("Session is already active");

            bridge.resumeObserved(id, prompt, directory, model, mode);
            return;
        }

        if (isRunning() || bridge.online(id))
            throw new ConflictException("Session is already active");

        bridge.resume(id, prompt, directory, model, false, mode);
    }

    Call steer(string prompt)
        => bridge.steer(id, prompt);

    void requestStop()
    {
        if (isRunning())
            execution.requestStop();
        else if (bridge.observedActive(id))
            bridge.cancelObserved(id);
        else if (bridge.online(id))
            throw new ConflictException("Cannot stop a session owned by another process");
    }

    void remove()
    {
        bridge.remove(id).wait();
        bridge.collect();
    }

    string logPath()
        => bridge.logPath(id);
}
