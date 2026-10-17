module daemon.interop.acp.permissions;

import daemon.interop.acp.client : AcpClient, AcpException, Incoming;
import daemon.interop.acp.frames;

import core.time : MonoTime;
import std.json : JSONValue;

package(daemon.interop.acp) Frame remapCancellation(Frame frame, JSONValue id)
{
    frame.value = JSONValue(frame.value.object.dup);
    JSONValue params = JSONValue(frame.value["params"].object.dup);
    params["requestId"] = id;
    frame.value["params"] = params;
    return frame;
}

package(daemon.interop.acp) void cancelPeer(AcpClient owner, long id)
{
    if (owner.peerOutput.isOpen)
    {
        owner.writeFrame(owner.peerOutput, owner.peerMutex, Frame(JSONValue([
            "jsonrpc": JSONValue("2.0"),
            "method": JSONValue(owner.cancelMethod),
            "params": JSONValue(["requestId": JSONValue(id)])
        ])));
    }
}

package(daemon.interop.acp) void cancelPermissions(AcpClient owner, string session)
{
    long[] pending;
    synchronized (owner.stateMutex)
    {
        foreach (id, request; owner.incoming)
        {
            if (request.frame.method == "session/request_permission" &&
                request.frame.value["params"]["sessionId"].str == session)
                pending ~= id;
        }
    }

    foreach (id; pending)
    {
        try
            owner.decide(session, id);
        catch (AcpException error)
        {
            // A competing native or HTTP decision may already have settled it.
            if (error.code != -32002)
                throw error;
        }
    }
}

JSONValue permissions(AcpClient owner, string session, long requestId = 0)
{
    owner.expire();
    JSONValue ret = JSONValue.emptyArray;
    synchronized (owner.stateMutex)
    {
        foreach (id, pending; owner.incoming)
        {
            if (pending.frame.method != "session/request_permission" || (requestId && id != requestId))
                continue;
            JSONValue params = pending.frame.value["params"];
            if (params["sessionId"].str != session)
                continue;
            JSONValue entry = JSONValue([
                "id": JSONValue(id),
                "session": JSONValue(session),
                "options": params["options"]
            ]);
            if (requestId)
                entry["context"] = params;
            ret.array ~= entry;
        }
    }
    return ret;
}

void decide(AcpClient owner, string session, long id, string option = null)
{
    Incoming pending;
    synchronized (owner.stateMutex)
    {
        Incoming* found = id in owner.incoming;
        if (found is null || found.deadline <= MonoTime.currTime ||
            found.frame.method != "session/request_permission" ||
            found.frame.value["params"]["sessionId"].str != session)
            throw new AcpException(-32002, "Permission request is no longer pending");
        pending = *found;
        if (option.length)
        {
            bool offered;
            foreach (entry; pending.frame.value["params"]["options"].array)
                offered = offered || entry["optionId"].str == option;
            if (!offered)
                throw new AcpException(-32602, "Permission option was not offered");
        }
        owner.incomingBytes -= pending.bytes;
        owner.incoming.remove(id);
    }
    JSONValue outcome = JSONValue(["outcome": JSONValue(option.length ? "selected" : "cancelled")]);
    if (option.length)
        outcome["optionId"] = JSONValue(option);
    owner.answer(pending.frame.value["id"], JSONValue(["outcome": outcome]));
    owner.cancelPeer(id);
}

void expire(AcpClient owner)
{
    Incoming[long] expired;
    synchronized (owner.stateMutex)
    {
        foreach (id; owner.incoming.keys)
        {
            if (owner.incoming[id].deadline <= MonoTime.currTime)
            {
                expired[id] = owner.incoming[id];
                owner.incomingBytes -= owner.incoming[id].bytes;
                owner.incoming.remove(id);
            }
        }
    }
    foreach (id, pending; expired)
    {
        if (pending.frame.method == "session/request_permission")
        {
            owner.answer(pending.frame.value["id"], JSONValue([
                "outcome": JSONValue(["outcome": JSONValue("cancelled")])
            ]));
        }
        else
            owner.answerError(pending.frame.value["id"], -32000, "Client request timed out");

        owner.cancelPeer(id);
    }
}
