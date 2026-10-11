module autonom.hooks;

import autonom.exception : InvalidInput;
import autonom.interop.session : Session;
import autonom.policy : PolicyResult;
import autonom.server : bridge, policy, readBody, respond;
import serverino : Output, Request, endpoint, route;

import std.exception : enforce;
import std.json : JSONValue, JSONType;

private:

void respondHook(string EVENT)(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    JSONValue data = readBody(request);
    enforce!InvalidInput("hook_event_name" in data.object && data["hook_event_name"].type == JSONType.string,
        "Expected a string hook_event_name");
    enforce!InvalidInput(data["hook_event_name"].str == EVENT, "Expected the "~EVENT~" hook event");
    respond(output, JSONValue(cast(JSONValue[string])null));
}

public:

@endpoint @route!"/api/hooks/pre-tool-use"
void preToolUse(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    JSONValue data = readBody(request);
    enforce!InvalidInput("hook_event_name" in data.object && data["hook_event_name"].type == JSONType.string,
        "Expected a string hook_event_name");
    enforce!InvalidInput(data["hook_event_name"].str == "PreToolUse", "Expected the PreToolUse hook event");

    if ("tool_name" !in data.object || data["tool_name"].type != JSONType.string || data["tool_name"].str.length == 0)
    {
        respond(output, JSONValue(cast(JSONValue[string])null));
        return;
    }

    string tool = data["tool_name"].str;
    JSONValue input = JSONValue.emptyObject;
    if ("tool_input" in data.object)
    {
        enforce!InvalidInput(data["tool_input"].type == JSONType.object, "Tool input must be an object");
        input = data["tool_input"];
    }

    string directory;
    if ("directory" in data.object && data["directory"].type == JSONType.string && data["directory"].str.length)
        directory = data["directory"].str;
    else if ("cwd" in data.object && data["cwd"].type == JSONType.string && data["cwd"].str.length)
        directory = data["cwd"].str;
    else if (request.get.has("directory") && request.get.read("directory").length)
        directory = request.get.read("directory");
    else if ("session_id" in data.object && data["session_id"].type == JSONType.string && data["session_id"].str.length)
    {
        Session session = bridge.findSession(data["session_id"].str);
        if (session !is null && session.execution !is null && session.execution.workspace.length)
            directory = session.execution.workspace;
    }

    if (directory.length == 0)
    {
        respond(output, JSONValue(cast(JSONValue[string])null));
        return;
    }

    if (policy is null)
    {
        respond(output, JSONValue([
            "decision": JSONValue("block"),
            "reason": JSONValue("Policy check is unavailable")
        ]));
        return;
    }

    try
    {
        PolicyResult result = policy.check(directory, tool, input);
        if (result.denied)
        {
            respond(output, JSONValue([
                "decision": JSONValue("block"),
                "reason": JSONValue(result.reason.length ? result.reason : "Denied by workspace policy")
            ]));
        }
        else
        {
            respond(output, JSONValue(cast(JSONValue[string])null));
        }
    }
    catch (Exception error)
    {
        respond(output, JSONValue([
            "decision": JSONValue("block"),
            "reason": JSONValue("Policy check failed: " ~ error.msg)
        ]));
    }
}

@endpoint @route!"/api/hooks/post-tool-use"
void postToolUse(Request request, Output output)
{
    respondHook!"PostToolUse"(request, output);
}

@endpoint @route!"/api/hooks/permission-request"
void permissionRequest(Request request, Output output)
{
    respondHook!"PermissionRequest"(request, output);
}

@endpoint @route!"/api/hooks/user-prompt-submit"
void userPromptSubmit(Request request, Output output)
{
    respondHook!"UserPromptSubmit"(request, output);
}

@endpoint @route!"/api/hooks/stop"
void stop(Request request, Output output)
{
    respondHook!"Stop"(request, output);
}

@endpoint @route!"/api/hooks/post-compaction"
void postCompaction(Request request, Output output)
{
    respondHook!"PostCompaction"(request, output);
}

@endpoint @route!"/api/hooks/session-start"
void sessionStart(Request request, Output output)
{
    respondHook!"SessionStart"(request, output);
}

@endpoint @route!"/api/hooks/session-end"
void sessionEnd(Request request, Output output)
{
    respondHook!"SessionEnd"(request, output);
}
