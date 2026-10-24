module daemon.agent.api;

import daemon.agent;
import daemon.api;
import daemon.http;
import daemon.interop.call : Call;
import daemon.interop.session : Session;

import serverino;

import std.json : JSONValue;

@endpoint @route!"/api/profiles"
void profiles(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    if (request.method == Request.Method.Get)
    {
        JSONValue[] ret;
        foreach (profile; profileStore.list())
            ret ~= profile.toJSON();

        respond(output, JSONValue(ret));
    }
    else
        respond(output, profileStore.create(readField!"name"(request)).toJSON(), 201);
}

/// Inspect a profile through the same API authority as the profile directory.
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

@endpoint @route!(matchesPath!"/api/profiles/<name>/session")
void profileSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    Profile profile = profileStore.get(routeParameter!"/api/profiles/<name>/session"(request));
    if (profile is null)
        respondError(output, 404, "Profile not found");
    else if (request.method == Request.Method.Post)
    {
        string session = readField!"id"(request);
        if (!bridge.access.client(request.header.read("x-autonom-client")))
        {
            Call execution = bridge.authenticate(request.header.read("x-autonom-run"), session);
            if (execution is null &&
                bridge.access.mcpSession(request.header.read("x-autonom-mcp")) != session)
                throw new ProfileConflictException("A session can register only its own managed identity");
            if (execution is null)
            {
                Session bound = bridge.findSession(session);
                execution = bound is null ? null : bound.execution;
            }
            if (execution !is null && execution.profileName.length)
            {
                if (execution.profileName != profile.name || !profileStarts.bind(execution))
                    throw new ProfileConflictException(
                        "The admitted profile start is no longer current");
                respond(output, profile.toJSON());
                return;
            }
        }

        respond(output, profileStore.register(profile.name, session).toJSON());
    }
    else if (profile.session !is null)
        respond(output, profile.session.toJSON());
    else
        respondError(output, 404, "Profile has no session");
}
