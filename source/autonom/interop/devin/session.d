module autonom.interop.devin.session;

import autonom.interop.devin.bridge : Devin;
import autonom.interop.session : Session, SessionStatus;

import std.algorithm : canFind;
import std.exception : enforce;
import std.file : exists, isDir;
import std.process : Pid, tryWait;
import std.stdio : File;
import std.typecons : Nullable;

/// A Devin CLI session managed through a Devin bridge.
class DevinSession : Session
{
private:
    Devin bridge;
    Pid process;
    Nullable!int _exitStatus;
    bool stopped;

public:
    this(string id, Devin bridge)
    {
        super(id);
        this.bridge = bridge;
    }

    /**
     * Starts a new session through a print, returning its handle.
     *
     * The print reply is written to the session log.
     */
    static Session start(
        Devin bridge,
        string prompt,
        string directory,
        string model = null
    )
    {
        enforce(directory.length && exists(directory) && isDir(directory),
            "An existing working directory is required");
        string[] previous = bridge.list(directory);
        string reply = bridge.print(prompt, directory, model);
        string[] created;
        foreach (id; bridge.list(directory))
        {
            if (!previous.canFind(id))
                created ~= id;
        }
        enforce(created.length == 1, "Could not determine the started session");
        Session ret = bridge.session(created[0]);
        File log = bridge.openLog(ret.id);
        scope(exit)
            log.close();

        log.write(reply);
        return ret;
    }

    override SessionStatus status()
    {
        bool running = isRunning();
        if (bridge.online(id))
            return SessionStatus.Online;
        if (running)
            return SessionStatus.Starting;
        if (!stopped && !_exitStatus.isNull && _exitStatus.get != 0)
            return SessionStatus.Failed;

        return SessionStatus.Offline;
    }

    override bool isRunning()
    {
        if (process is null)
            return false;

        typeof(tryWait(Pid.init)) result = tryWait(process);
        if (!result.terminated)
            return true;

        _exitStatus = result.status;
        process = null;
        return false;
    }

    override void resume(string prompt, string directory, string model = null)
    {
        enforce(directory.length && exists(directory) && isDir(directory),
            "An existing working directory is required");
        enforce(!isRunning() && !bridge.online(id), "Session is already active");
        _exitStatus.nullify();
        stopped = false;
        process = bridge.resume(id, prompt, directory, model);
    }

    override void stop()
    {
        if (!isRunning())
        {
            enforce(!bridge.online(id), "Cannot stop a session owned by another process");
            return;
        }

        _exitStatus = bridge.terminate(process);
        process = null;
        stopped = true;
    }

    override void remove()
    {
        stop();
        bridge.remove(id);
    }

    override ref const(Nullable!int) exitStatus() const
        => _exitStatus;

    override string logPath()
        => bridge.logPath(id);
}
