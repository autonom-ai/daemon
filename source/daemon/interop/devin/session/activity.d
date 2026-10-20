module daemon.interop.devin.session.activity;

import daemon.exception : ConflictException;
import daemon.interop.acp : AcpClient, AcpException, activity;
import daemon.interop.call : Call, CallKind, CallResult, CallStatus;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.calls;
import daemon.interop.devin.connection;
import daemon.interop.devin.control : controlRequest;
import daemon.interop.devin.prompt : deliverPrompt;
import daemon.interop.session : TurnStatus;

import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.json : JSONValue;

TurnStatus activity(Bridge owner, string id)
{
    if (owner.observedSession(id))
    {
        if (!owner.online(id))
            return TurnStatus.Idle;

        try
        {
            JSONValue result = controlRequest(owner.controlSocket(owner.observedConnection(id)),
                owner.access.clientToken, "autonom/activity", JSONValue(["sessionId": JSONValue(id)]),
                null, 250.msecs);
            return cast(TurnStatus)result.str;
        }
        catch (Exception)
            return TurnStatus.Unknown;
    }

    foreach (call; owner.executions)
    {
        if (!call.automatic && call.running && call.sessionId == id)
        {
            AcpClient connection = call.connection;
            if (connection is null)
                return TurnStatus.Unknown;

            TurnStatus ret = connection.activity(id);
            if (ret == TurnStatus.Waiting)
                return ret;
            if (call.status != CallStatus.Running || !call.acceptingSteer || ret == TurnStatus.Idle)
                return TurnStatus.Unknown;

            return ret;
        }
    }

    return owner.online(id) ? TurnStatus.Unknown : TurnStatus.Idle;
}

Call deliver(Bridge owner, string id, string prompt)
{
    if (!owner.access.managed(id))
        throw new ConflictException("Automatic delivery requires a managed session");

    if (owner.observedSession(id))
    {
        Call ret = owner.newCall(CallKind.Resume, owner.observedDirectory(id), null, id);
        owner.launch(ret, prompt, false, null, owner.observedConnection(id), true);
        return ret;
    }

    foreach (call; owner.executions)
    {
        AcpClient connection = call.connection;
        if (!call.running || call.sessionId != id || connection is null)
            continue;

        owner.checkCapacity();
        Call ret = owner.newCall(CallKind.Resume, call.workspace, call.model, id);
        ret.automatic = true;
        owner.executions[ret.id] = ret;
        ret._timeout = owner.executionTimeout;
        ret.deadline = MonoTime.currTime + ret.timeout;
        ret.connection = connection;
        ret.monitor = new Thread({
            CallResult result;
            try
            {
                result = deliverPrompt(ret, connection, id, prompt);
            }
            catch (AcpException error)
            {
                if (error.code == -32015)
                    result.deferred = true;
                else
                    result.error = error.msg.idup;
            }
            catch (Exception error)
                result.error = error.msg.idup;

            ret.finish(result);
        });
        ret.monitor.start();
        return ret;
    }

    throw new ConflictException("Session has no controllable connection");
}
