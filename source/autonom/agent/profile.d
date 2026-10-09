module autonom.agent.profile;

import autonom.interop.session : Session;
import autonom.server : profileStore, respond;
import serverino : Output, Request, endpoint, route;

import std.algorithm : startsWith;
import std.array : split;
import std.json : JSONValue;

@endpoint @route!(profileRoute)
void getProfile(Request request, Output output)
{
    Profile profile = profileStore.get(request.path["/api/profiles/".length..$].split('/')[0]);
    if (profile is null)
        respond(output, JSONValue(["error": JSONValue("Profile not found")]), 404);
    else if (request.method == Request.Method.Get)
        respond(output, profile.toJSON());
    else
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
}

private:

bool profileRoute(const Request request)
{
    enum PREFIX = "/api/profiles/";
    if (!request.path.startsWith(PREFIX))
        return false;

    return request.path[PREFIX.length..$].split('/').length == 1;
}

public:

/// A named agent identity linked to at most one session.
class Profile
{
public:
    const string name;
    Session session;

    this(string name, Session session = null)
    {
        this.name = name;
        this.session = session;
    }

    JSONValue toJSON()
    {
        return JSONValue([
            "name": JSONValue(name),
            "session": session is null ? JSONValue(null) : session.toJSON()
        ]);
    }
}
