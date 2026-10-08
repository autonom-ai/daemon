module autonom.policy.endpoint;

import autonom.policy.result : PolicyResult;
import autonom.server : policy, readBody, respond;
import serverino : Output, Request, endpoint, route;

import std.exception : enforce;
import std.json : JSONType, JSONValue;

public:

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
