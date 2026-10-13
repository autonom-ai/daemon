module autonom.interop.devin.session;

import autonom.exception;
import autonom.interop.devin.bridge;
import autonom.interop.devin.db : SessionMetadata;
import autonom.interop.execution;
import autonom.interop.session;


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

    override SessionMetadata metadata()
        => bridge.sessionMetadata(id);

    override SessionStatus status()
    {
        if (execution !is null && execution.status == ExecutionStatus.Stopping)
            return SessionStatus.Stopping;

        if (isRunning())
            return bridge.online(id) ? SessionStatus.Online : SessionStatus.Starting;
        if (bridge.online(id))
            return SessionStatus.Loaded;

        if (execution !is null && (execution.status == ExecutionStatus.Failed ||
            execution.status == ExecutionStatus.Interrupted))
            return SessionStatus.Failed;

        return SessionStatus.Offline;
    }

    override void resume(
        string prompt,
        string directory,
        string model = null,
        string mode = null
    )
    {
        if (isRunning() || bridge.online(id))
            throw new ConflictException("Session is already active");

        bindExecution(bridge.resume(id, prompt, directory, model, null, mode));
    }

    override void requestStop()
    {
        if (isRunning())
            execution.requestStop();
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
