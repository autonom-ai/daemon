module daemon.interop.session;

import daemon.exception : InvalidInputException;
import daemon.interop.call : Call;
import daemon.interop.metadata : SessionMetadata;

import std.ascii : isAlphaNum;
import std.json : JSONValue;
import std.typecons : Nullable;

enum SessionStatus : string
{
    Offline = "offline",
    Starting = "starting",
    Online = "online",
    Stopping = "stopping"
}

enum TurnStatus : string
{
    Idle = "idle",
    Running = "running",
    Waiting = "waiting",
    Unknown = "unknown"
}

/// Provider-neutral session identity and operations used by profiles and scheduling.
abstract class Session
{
    const string id;

    this(string id)
    {
        validateId(id);
        this.id = id.idup;
    }

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

    abstract Call execution();

    abstract SessionMetadata metadata();

    abstract SessionStatus status();

    abstract bool hasActiveCall();

    abstract TurnStatus activity();

    /// Deliver automatic context through the owner, preserving pending human requests.
    abstract Call deliver(string prompt);

    abstract void resume(string prompt, string directory, string model = null, string mode = null);

    abstract Call steer(string prompt);

    abstract void requestStop();

    abstract void stop();

    abstract void remove();

    abstract JSONValue toJSON(bool refresh = true);

    abstract string logPath();

    abstract Nullable!int exitStatus();

    string model()
        => metadata.model;

    string title()
        => metadata.title;

    string mode()
        => metadata.mode;

    string workspace()
        => metadata.directory;
}
