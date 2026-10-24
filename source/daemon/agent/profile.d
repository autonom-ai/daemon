module daemon.agent.profile;

import daemon.interop.session : Session;

import std.json : JSONValue;

/// Reserved local operator identity, never a managed profile name.
enum humanName = "human";

/// Domain profile identity and its current provider session, without HTTP assembly.
class Profile
{
private:
    Session _session;

package(daemon.agent):
    void bind(Session session)
    {
        _session = session;
    }

public:
    const string name;

    Session session()
        => _session;

    this(string name, Session session = null)
    {
        this.name = name.idup;
        _session = session;
    }

    JSONValue toJSON(bool refresh = true)
    {
        return JSONValue([
            "name": JSONValue(name),
            "session": session is null ? JSONValue(null) : session.toJSON(refresh)
        ]);
    }
}
