module autonom.hooks;

import autonom.agent;
import autonom.exception;
import autonom.interop.session;
import autonom.policy;
import autonom.server;
import serverino;

import std.algorithm.searching : startsWith;
import std.json : JSONValue, JSONType;

private:

enum MCP_PREFIX = "mcp__autonom-coord__";

bool coordinationTool(string tool)
    => tool.startsWith(MCP_PREFIX);

bool readsEvents(string tool)
    => tool == MCP_PREFIX~"read_events";

bool blockedByEvents(string tool, string session, Output output)
{
    if (!session.length || readsEvents(tool))
        return false;

    Profile profile;
    try
    {
        if (events is null)
            throw new Exception("Coordination is unavailable");
        profile = profileStore.profileFor(session);
    }
    catch (Exception)
    {
        respond(output, JSONValue([
            "decision": JSONValue("block"),
            "reason": JSONValue("Profile access could not be verified")
        ]));
        return true;
    }

    if (profile is null || !events.unread(profile).length)
        return false;

    respond(output, JSONValue([
        "decision": JSONValue("block"),
        "reason": JSONValue("You have unread events - read them first: call read_events")
    ]));
    return true;
}


void respondHook(string EVENT)(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    JSONValue data = readBody(request);
    if ("hook_event_name" !in data.object || data["hook_event_name"].type != JSONType.string)
        throw new InvalidInputException("Expected a string hook_event_name");
    if (data["hook_event_name"].str != EVENT)
        throw new InvalidInputException("Expected the "~EVENT~" hook event");

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
    if ("hook_event_name" !in data.object || data["hook_event_name"].type != JSONType.string)
        throw new InvalidInputException("Expected a string hook_event_name");
    if (data["hook_event_name"].str != "PreToolUse")
        throw new InvalidInputException("Expected the PreToolUse hook event");

    if ("tool_name" !in data.object || data["tool_name"].type != JSONType.string || data["tool_name"].str.length == 0)
    {
        respond(output, JSONValue(cast(JSONValue[string])null));
        return;
    }

    string tool = data["tool_name"].str;
    JSONValue input = JSONValue.emptyObject;
    if ("tool_input" in data.object)
    {
        if (data["tool_input"].type != JSONType.object)
            throw new InvalidInputException("Tool input must be an object");

        input = data["tool_input"];
    }

    string session = "session_id" in data.object && data["session_id"].type == JSONType.string ?
        data["session_id"].str : null;
    if (blockedByEvents(tool, session, output))
        return;

    string directory;
    if ("directory" in data.object && data["directory"].type == JSONType.string && data["directory"].str.length)
        directory = data["directory"].str;
    else if ("cwd" in data.object && data["cwd"].type == JSONType.string && data["cwd"].str.length)
        directory = data["cwd"].str;
    else if (request.get.has("directory") && request.get.read("directory").length)
        directory = request.get.read("directory");
    else if (session.length)
    {
        Session found = bridge.findSession(session);
        if (found !is null && found.execution !is null && found.execution.workspace.length)
            directory = found.execution.workspace;
    }

    if (directory.length)
    {
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
                return;
            }
        }
        catch (Exception error)
        {
            respond(output, JSONValue([
                "decision": JSONValue("block"),
                "reason": JSONValue("Policy check failed: " ~ error.msg)
            ]));
            return;
        }
    }

    if (session.length && directory.length)
        scheduler.adopt(session, directory);

    if (coordinationTool(tool) && session.length)
    {
        respond(output, JSONValue([
            "hookSpecificOutput": JSONValue([
                "hookEventName": JSONValue("PreToolUse"),
                "updatedInput": JSONValue(["session_id": JSONValue(session)])
            ])
        ]));
        return;
    }

    respond(output, JSONValue(cast(JSONValue[string])null));
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
