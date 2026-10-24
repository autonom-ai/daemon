module daemon.interop.session;

import daemon.exception : InvalidInputException;
import daemon.interop.call : Call;
import daemon.interop.metadata : SessionMetadata;

import std.ascii : isAlphaNum;
import std.json : JSONValue;
import std.typecons : Nullable;

/// Provider-qualified backend identity, distinct from a profile or ACP conversation ID.
struct SessionKey
{
private:
    string _provider;
    string _id;

public:
    this(string provider, string id)
    {
        _provider = provider.idup;
        _id = id.idup;
        validate();
    }

    /// The canonical provider namespace.
    string provider() const
        => _provider;

    /// The provider's opaque session ID, owned independently of input buffers.
    string id() const
        => _id;

    /// Reject an uninitialized key or a noncanonical provider/session representation.
    void validate() const
    {
        if (!_provider.length || _provider.length > 32 || _provider[0] < 'a' || _provider[0] > 'z')
            throw new InvalidInputException("Invalid provider name");
        foreach (character; _provider)
        {
            if (!(character >= 'a' && character <= 'z') && !(character >= '0' && character <= '9') &&
                character != '-' && character != '_')
                throw new InvalidInputException("Invalid provider name");
        }

        Session.validateId(_id);
    }
}

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
