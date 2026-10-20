module daemon.interop.devin.calls;

import daemon.exception : ConflictException;
import daemon.interop.call : Call, CallKind, CallStatus;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.connection : sweepObserved;
import daemon.interop.devin.history : recordExecution;
import daemon.interop.devin.session : Session;
import daemon.interop.devin.session.control : removeLog;

import core.time : MonoTime;
import std.algorithm : sort;
import std.uuid : randomUUID;

package(daemon.interop.devin):
Call newCall(
    Bridge owner,
    CallKind kind,
    string directory,
    string model,
    string sessionId = null
)
{
    return new Call(
        owner.executionDir,
        owner.logDir,
        randomUUID().toString(),
        kind,
        directory,
        model,
        sessionId
    );
}

Call findCall(Bridge owner, string id)
{
    Session.validateId(id);
    Call* found = id in owner.executions;
    return found is null ? null : *found;
}

Call[] listCalls(Bridge owner, string directory = null)
{
    Call[] ret;
    foreach (execution; owner.executions)
    {
        if (!directory.length || execution.workspace == directory)
            ret ~= execution;
    }

    ret.sort!((left, right) => left.createdAt < right.createdAt);
    return ret;
}

string[] collectCalls(Bridge owner)
{
    owner.sweepObserved();
    Call[] ready;
    foreach (execution; owner.executions)
    {
        if (!execution.running && !execution.collected)
            ready ~= execution;
    }

    ready.sort!((left, right) {
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
                owner.removeLog(id);
                owner.sessions.remove(id);
                owner.access.forget(id);
                owner.removed[id] = true;
            }
            else if (id !in owner.removed)
            {
                if (execution.kind == CallKind.Start || execution.kind == CallKind.Print)
                    owner.access.remember(id, execution.trusted);

                Session session = owner.session(id);
                if (!execution.automatic &&
                    (session.execution is null || session.execution.createdAt <= execution.createdAt))
                    session.bindCall(execution);
            }
        }

        execution.collected = true;
        owner.recordExecution(execution);
    }

    Call[] settledCalls;
    foreach (call; owner.executions.byValue)
    {
        if (!call.running)
            settledCalls ~= call;
    }

    settledCalls.sort!((left, right) {
        if (left.settled != right.settled)
            return left.settled < right.settled;
        if (left.createdAt != right.createdAt)
            return left.createdAt < right.createdAt;
        return left.id < right.id;
    });

    MonoTime now = MonoTime.currTime;
    foreach (call; settledCalls)
    {
        bool expired = (now - call.settled > owner.callSettleTimeout);
        bool overCapacity = (owner.executions.length > owner.callCapacity);
        if (expired || overCapacity)
        {
            owner.recordExecution(call);
            owner.executions.remove(call.id);
        }
        else
            break;
    }
    owner.access.collect();
    return owner.removed.keys;
}

void stopCalls(Bridge owner)
{
    foreach (execution; owner.executions)
        execution.requestStop();
}

void closeCalls(Bridge owner)
{
    Exception failure;
    foreach (execution; owner.executions)
    {
        try
            execution.requestStop();
        catch (Exception error)
        {
            if (failure is null)
                failure = error;
        }
    }

    foreach (execution; owner.executions)
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

void checkCapacity(Bridge owner)
{
    size_t active;
    foreach (entry; owner.executions)
        active += entry.running;

    if (active >= owner.maxConcurrentCalls)
        throw new ConflictException("Call capacity reached");
}
