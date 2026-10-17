module daemon.agent.profile;

import daemon.api;
import daemon.http;
import daemon.interop.session : Session;

import serverino;

import std.json : JSONValue;

enum humanName = "human";

@endpoint @route!(matchesPath!"/api/profiles/<name>")
void getProfile(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    Profile profile = profileStore.get(routeParameter!"/api/profiles/<name>"(request));
    if (profile is null)
        respondError(output, 404, "Profile not found");
    else
        respond(output, profile.toJSON());
}

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
