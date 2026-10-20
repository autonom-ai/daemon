module daemon.interop.acp.routing;

import daemon.interop.acp.client : AcpClient, AcpException, Response, Incoming;
import daemon.interop.acp.frames;
import daemon.interop.acp.permissions;
import daemon.interop.session : TurnStatus;
import daemon.interop.acp.activity : turnActivity;

import core.time : MonoTime;
import std.json : JSONType, JSONValue;

package(daemon.interop.acp):
void dispatch(AcpClient owner, Frame frame)
{
    if (frame.request)
    {
        if (!frame.identified)
        {
            if (frame.method == owner.cancelMethod)
            {
                long id;
                string session;
                synchronized (owner.stateMutex)
                {
                    foreach (identity, pending; owner.incoming)
                    {
                        if (pending.frame.value["id"] != frame.value["params"]["requestId"])
                            continue;

                        id = identity;
                        if (pending.frame.method == "session/request_permission")
                            session = pending.frame.value["params"]["sessionId"].str;

                        break;
                    }
                }

                if (id && owner.peerOutput.isOpen)
                    owner.writeFrame(owner.peerOutput, owner.peerMutex, remapCancellation(frame, JSONValue(id)));
                else if (id && session.length)
                {
                    try
                        owner.decide(session, id);
                    catch (AcpException error)
                    {
                        if (error.code != -32002)
                            throw error;
                    }
                }

                return;
            }

            if (owner.notification !is null)
                owner.notification(frame.value);
            if (owner.peerOutput.isOpen)
                owner.writeFrame(owner.peerOutput, owner.peerMutex, frame);
            return;
        }
        if (frame.method == "session/request_permission" || owner.peerOutput.isOpen)
        {
            long id;
            size_t bytes = frame.encode().length;
            synchronized (owner.stateMutex)
            {
                if (owner.incoming.length >= 64 || bytes > frameLimit - owner.incomingBytes)
                    throw new AcpException(-32000, "Too many outstanding backend requests");
                id = owner.allocate();
                owner.incoming[id] = Incoming(frame, MonoTime.currTime + owner.permissionTimeout, bytes);
                owner.incomingBytes += bytes;
            }
            if (owner.peerOutput.isOpen)
                owner.writeFrame(owner.peerOutput, owner.peerMutex, frame.withId(JSONValue(id)));
            return;
        }
        try
        {
            if (owner.agentRequest is null)
                throw new AcpException(-32601, "Method not found");
            owner.answer(frame.value["id"], owner.agentRequest(frame.value));
        }
        catch (AcpException error)
            owner.answerError(frame.value["id"], error.code, error.msg);
        catch (Exception error)
            owner.answerError(frame.value["id"], -32603, error.msg);
        return;
    }

    JSONValue id = frame.value["id"];
    if (id.type != JSONType.integer && id.type != JSONType.uinteger)
        return;
    long identity = id.type == JSONType.integer ? id.integer : cast(long)id.uinteger;
    Response response;
    synchronized (owner.stateMutex)
    {
        Response* found = identity in owner.requests;
        if (found is null || found.done)
            return;
        response = *found;
    }
    // Required admission runs on this path before a successful reply is delivered.
    if (owner.beforeReply !is null)
        owner.beforeReply(frame, response.sent);
    if (response.peer)
    {
        synchronized (owner.stateMutex)
            owner.requests.remove(identity);
        owner.writeFrame(owner.peerOutput, owner.peerMutex, frame.withId(response.originalId));
        return;
    }
    synchronized (owner.stateMutex)
    {
        response.done = true;
        if ("error" in frame.value.object)
        {
            JSONValue error = frame.value["error"];
            response.errorCode = cast(int)error["code"].integer;
            response.error = error["message"].str;
        }
        else
            response.result = frame.value["result"];
        owner.updated.notifyAll();
    }
}

long submit(AcpClient owner, Frame frame, bool peer, bool automatic = false)
{
    Response response = new Response();
    long id;
    synchronized (owner.stateMutex)
    {
        if (owner.terminated || owner.closing)
            throw new AcpException(-32000, "ACP connection is closed");
        if (owner.requests.length >= requestLimit)
            throw new AcpException(-32000, "Too many outstanding ACP requests");
        if (automatic && owner.turnActivity(frame.value["params"]["sessionId"].str) == TurnStatus.Waiting)
            throw new AcpException(-32015, "Session is waiting for a client response");

        id = owner.allocate();
        response.peer = peer;
        response.originalId = frame.value["id"];
        frame = frame.withId(JSONValue(id));
        response.sent = frame;
        owner.requests[id] = response;
    }
    try
    {
        if (owner.outgoing !is null)
            owner.outgoing(frame);
        synchronized (owner.stateMutex)
            response.sent = frame;
        owner.writeFrame(owner.toAgent, owner.writeMutex, frame);
    }
    catch (Exception error)
    {
        synchronized (owner.stateMutex)
            owner.requests.remove(id);
        throw error;
    }
    return id;
}

void receivePeer(AcpClient owner, Frame frame)
{
    if (frame.request)
    {
        if (frame.identified)
            owner.submit(frame, true);
        else
        {
            if (frame.method == owner.cancelMethod)
            {
                long id;
                synchronized (owner.stateMutex)
                {
                    foreach (identity, response; owner.requests)
                    {
                        if (response.peer && response.originalId == frame.value["params"]["requestId"])
                        {
                            id = identity;
                            break;
                        }
                    }
                }

                if (id)
                    owner.writeFrame(owner.toAgent, owner.writeMutex, remapCancellation(frame, JSONValue(id)));

                return;
            }

            if (frame.method == "session/cancel")
                owner.cancelPermissions(frame.value["params"]["sessionId"].str);

            owner.writeFrame(owner.toAgent, owner.writeMutex, frame);
        }

        return;
    }
    JSONValue id = frame.value["id"];
    if (id.type != JSONType.integer)
        return;
    Incoming pending;
    synchronized (owner.stateMutex)
    {
        Incoming* found = id.integer in owner.incoming;
        if (found is null)
            return;
        pending = *found;
        if (pending.deadline <= MonoTime.currTime)
            return;
        if (pending.frame.method == "session/request_permission" && "result" in frame.value.object)
        {
            JSONValue result = frame.value["result"];
            JSONValue outcome = result["outcome"];
            string kind = outcome["outcome"].str;
            if (kind != "selected" && kind != "cancelled")
                throw new AcpException(-32602, "Invalid native permission outcome");
            if (kind == "selected")
            {
                bool offered;
                foreach (option; pending.frame.value["params"]["options"].array)
                    offered = offered || option["optionId"].str == outcome["optionId"].str;
                if (!offered)
                    throw new AcpException(-32602, "Native permission option was not offered");
            }
        }
        owner.incomingBytes -= pending.bytes;
        owner.incoming.remove(id.integer);
    }
    owner.writeFrame(owner.toAgent, owner.writeMutex, frame.withId(pending.frame.value["id"]));
}

long allocate(AcpClient owner)
{
    if (owner.nextId == long.max)
        throw new AcpException(-32000, "ACP request identity space exhausted");
    return owner.nextId++;
}
