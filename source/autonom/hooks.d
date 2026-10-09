module autonom.hooks;

import autonom.server : readBody, respond;
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
    enforce("hook_event_name" in data.object && data["hook_event_name"].type == JSONType.string,
        "Expected a string hook_event_name");
    enforce(data["hook_event_name"].str == EVENT, "Expected the "~EVENT~" hook event");
    respond(output, JSONValue(cast(JSONValue[string])null));
}

public:

@endpoint @route!"/api/hooks/pre-tool-use"
void preToolUse(Request request, Output output)
{
    respondHook!"PreToolUse"(request, output);
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
