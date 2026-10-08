module autonom.session.cleanup;

import autonom.server : profileStore, readBody, respond;
import serverino : Output, Request, endpoint, route;

import std.exception : enforce;
import std.json : JSONType, JSONValue;

public:

@endpoint @route!"/api/sessions/remove"
void removeSessions(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    JSONValue data = readBody(request);
    enforce(data.object.length == 1 && "ids" in data.object, "Expected only the ids field");
    enforce(data["ids"].type == JSONType.array, "Session IDs must be an array");
    bool[string] seen;
    foreach (id; data["ids"].array)
    {
        enforce(id.type == JSONType.string, "Session IDs must be strings");
        enforce(id.str !in seen, "Session IDs must be unique");
        profileStore.sessionFor(id.str);
        seen[id.str] = true;
    }

    JSONValue ret = JSONValue.emptyObject;
    ret["removed"] = JSONValue.emptyArray;
    ret["failed"] = JSONValue.emptyArray;
    foreach (id; data["ids"].array)
    {
        try
        {
            profileStore.removeSession(id.str);
            ret["removed"].array ~= id;
        }
        catch (Exception)
            ret["failed"].array ~= id;
    }

    respond(output, ret, ret["failed"].array.length ? 503 : 200);
}
