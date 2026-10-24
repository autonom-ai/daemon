module daemon.agent.profile;

import daemon.interop.session : Session;

import std.json : JSONValue;

/// Reserved local operator identity, never a managed profile name.
enum humanName = "human";

/// Worker-lifetime identity of one Profile Session binding version. A new
/// value is created only when the bound Session reference changes; it is a
/// staleness marker for pending admissions, never a persisted or bearer grant.
final class BindingGeneration
{ }

/// Domain profile identity and its current provider session, without HTTP assembly.
class Profile
{
private:
    Session _session;
    BindingGeneration marker_;

package(daemon.agent):
    void bind(Session session)
    {
        if (session !is _session)
            marker_ = new BindingGeneration();
        _session = session;
    }

public:
    const string name;

    Session session()
        => _session;

    /// Identity marker for the current worker-lifetime Session binding.
    BindingGeneration bindingGeneration()
        => marker_;

    this(string name, Session session = null)
    {
        this.name = name.idup;
        marker_ = new BindingGeneration();
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
