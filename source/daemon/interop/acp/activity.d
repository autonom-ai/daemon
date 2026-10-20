module daemon.interop.acp.activity;

import daemon.interop.acp.client : AcpClient;
import daemon.interop.acp.frames : Frame;
import daemon.interop.acp.routing : submit;
import daemon.interop.session : TurnStatus;

import std.json : JSONValue;

TurnStatus activity(AcpClient owner, string session)
{
    synchronized (owner.stateMutex)
    {
        if (owner.terminated || owner.closing)
            return TurnStatus.Unknown;

        return owner.turnActivity(session);
    }
}

/// Admission and the pending-client-request check share the correlation mutex.
long deliver(AcpClient owner, JSONValue params)
{
    return owner.submit(Frame(JSONValue([
        "jsonrpc": JSONValue("2.0"),
        "id": JSONValue(null),
        "method": JSONValue("session/prompt"),
        "params": params
    ])), false, true);
}

package(daemon.interop.acp):
TurnStatus turnActivity(AcpClient owner, string session)
{
    foreach (pending; owner.incoming)
    {
        JSONValue params = pending.frame.value["params"];
        if ("sessionId" !in params.object || params["sessionId"].str == session)
            return TurnStatus.Waiting;
    }

    foreach (response; owner.requests)
    {
        if (!response.done && response.sent.method == "session/prompt" &&
            response.sent.value["params"]["sessionId"].str == session)
            return TurnStatus.Running;
    }

    return TurnStatus.Idle;
}
