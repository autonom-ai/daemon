module autonom.interop.devin.session;

import autonom.exception;
import autonom.interop.devin.bridge;
import autonom.interop.execution;
import autonom.interop.session;

import std.exception : enforce;

class DevinSession : Session
{
private:
    Devin bridge;

public:
    this(string id, Devin bridge)
    {
        super(id);
        this.bridge = bridge;
    }

    override SessionStatus status()
    {
        if (execution !is null && execution.status == ExecutionStatus.Stopping)
            return SessionStatus.Stopping;

        if (bridge.online(id))
            return SessionStatus.Online;

        if (isRunning())
            return SessionStatus.Starting;

        if (execution !is null && (execution.status == ExecutionStatus.Failed ||
            execution.status == ExecutionStatus.Interrupted))
            return SessionStatus.Failed;

        return SessionStatus.Offline;
    }

    override void resume(string prompt, string directory, string model = null)
    {
        enforce!ConflictException(!isRunning() && !bridge.online(id), "Session is already active");
        bindExecution(bridge.resume(id, prompt, directory, model));
    }

    override void requestStop()
    {
        if (isRunning())
            execution.requestStop();
        else
            enforce!ConflictException(!bridge.online(id), "Cannot stop a session owned by another process");
    }

    override void remove()
    {
        bridge.remove(id).wait();
        bridge.collect();
    }

    override string logPath()
        => bridge.logPath(id);
}
