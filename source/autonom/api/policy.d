/// HTTP endpoint for workspace policy checks.
module autonom.api.policy;

import autonom.api.http : readBody, respond;
import autonom.policy : PolicyResult;
import autonom.server : policy;
import serverino : Output, Request, endpoint, route;

import std.exception : enforce;
import std.json : JSONType, JSONValue;

/// Checks a tool request, returning a denial with HTTP 503 when evaluation fails.
@endpoint @route!"/api/policy/check"
void checkPolicy(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    JSONValue data = readBody(request);
    enforce("directory" in data.object && "tool" in data.object, "Expected directory and tool");
    enforce(data["directory"].type == JSONType.string && data["tool"].type == JSONType.string,
        "Directory and tool must be strings");
    foreach (name; data.object.keys)
        enforce(name == "directory" || name == "tool" || name == "input", "Unexpected policy request field");

    if ("input" !in data.object)
        data["input"] = JSONValue.emptyObject;

    enforce(data["input"].type == JSONType.object, "Tool input must be an object");
    try
        respond(output, policy.check(data["directory"].str, data["tool"].str, data["input"]).toJSON());
    catch (Exception)
        respond(output, PolicyResult(true, "Policy check failed").toJSON(), 503);
}
