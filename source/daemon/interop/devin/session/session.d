module daemon.interop.devin.session.session;

import daemon.exception : ConflictException;
import daemon.interop.call : Call, CallStatus;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.connection;
import daemon.interop.devin.session.control;
import daemon.interop.devin.session.activity;
import daemon.interop.metadata : SessionMetadata;
import daemon.interop.session : SessionBase = Session, SessionStatus, TurnStatus;

import std.json : JSONValue;
import std.typecons : Nullable;

class Session : SessionBase
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
    this(string id, Bridge bridge)
    {
        super(id);
        this.bridge = bridge;
    }

    override Call execution()
        => _execution;

    override bool hasActiveCall()
        => _execution !is null && _execution.running;

    override TurnStatus activity()
        => daemon.interop.devin.session.activity.activity(bridge, id);

    override Call deliver(string prompt)
        => daemon.interop.devin.session.activity.deliver(bridge, id, prompt);

    override void stop()
    {
        requestStop();
        if (_execution !is null)
            _execution.wait();
    }

    override Nullable!int exitStatus()
    {
        if (_execution is null || _execution.exitStatus.isNull)
            return Nullable!int.init;

        return Nullable!int(cast(int)_execution.exitStatus.integer);
    }

    override JSONValue toJSON(bool refresh = true)
    {
        if (refresh)
            _metadata = bridge.sessionMetadata(id);

        SessionMetadata data = metadata;

        JSONValue ret = data.toJSON();
        ret["id"] = JSONValue(id);
        ret["status"] = JSONValue(cast(string)status);
        ret["activity"] = JSONValue(cast(string)activity);
        ret["exitStatus"] = exitStatus.isNull ? JSONValue(null) : JSONValue(exitStatus.get);
        ret["executionId"] = _execution is null ? JSONValue(null) : JSONValue(_execution.id);
        return ret;
    }

    override SessionMetadata metadata()
    {
        SessionMetadata ret = _metadata;
        if (_execution !is null)
        {
            if (!ret.model.length)
                ret.model = _execution.model;
            if (!ret.mode.length)
                ret.mode = _execution.mode;
            if (!ret.directory.length)
                ret.directory = _execution.workspace;
        }
        if (!ret.id.length)
        {
            if (!ret.directory.length)
                ret.directory = bridge.observedDirectory(id);

            if (hasActiveCall() || bridge.observedSession(id))
                ret.acp = "autonom";
        }

        return ret;
    }

    override SessionStatus status()
    {
        if (execution !is null && execution.status == CallStatus.Stopping)
            return SessionStatus.Stopping;

        if (hasActiveCall())
            return bridge.online(id) ? SessionStatus.Online : SessionStatus.Starting;
        if (bridge.online(id))
            return SessionStatus.Online;

        return SessionStatus.Offline;
    }

    override void resume(
        string prompt,
        string directory,
        string model = null,
        string mode = null
    )
    {
        if (bridge.observedSession(id))
        {
            if (hasActiveCall() || activity != TurnStatus.Idle)
                throw new ConflictException("Session is already active");

            bridge.resumeObserved(id, prompt, directory, model, mode);
            return;
        }

        if (hasActiveCall() || bridge.online(id))
            throw new ConflictException("Session is already active");

        bridge.resume(id, prompt, directory, model, false, mode);
    }

    override Call steer(string prompt)
        => bridge.steer(id, prompt);

    override void requestStop()
    {
        if (hasActiveCall())
            execution.requestStop();
        else if (bridge.observedSession(id) && activity != TurnStatus.Idle)
            bridge.cancelObserved(id);
        else if (bridge.online(id))
            throw new ConflictException("Cannot stop a session owned by another process");
    }

    override void remove()
    {
        bridge.remove(id).wait();
        bridge.collect();
    }

    override string logPath()
        => bridge.logPath(id);
}
