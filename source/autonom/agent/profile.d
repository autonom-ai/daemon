module autonom.agent.profile;

import autonom.interop.session : Session;
import autonom.server : acceptMethod, profileStore, respond, matchesPath, routeParameter;
import serverino : Output, Request, endpoint, route;

import std.json : JSONValue;

@endpoint @route!(matchesPath!"/api/profiles/<name>")
void getProfile(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    Profile profile = profileStore.get(routeParameter!"/api/profiles/<name>"(request));
    if (profile is null)
        respond(output, JSONValue(["error": JSONValue("Profile not found")]), 404);
    else
        respond(output, profile.toJSON());
}

/// A named agent identity linked to at most one session.
class Profile
{
private:
    Session _session;

package(autonom.agent):
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

    JSONValue toJSON()
    {
        return JSONValue([
            "name": JSONValue(name),
            "session": session is null ? JSONValue(null) : session.toJSON()
        ]);
    }
}
