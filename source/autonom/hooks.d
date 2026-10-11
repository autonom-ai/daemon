module autonom.hooks;

import autonom.agent.profile : Profile;
import autonom.exception : InvalidInput;
import autonom.interop.session : Session;
import autonom.policy : PolicyResult;
import autonom.server : bridge, bus, policy, profileStore, readBody, respond;
import serverino : Output, Request, endpoint, route;

import std.algorithm.searching : startsWith;
import std.exception : enforce;
import std.json : JSONValue, JSONType;

private:

enum MCP_PREFIX = "mcp__autonom-coord__";

/// Reports whether a tool belongs to the coordination MCP.
bool coordinationTool(string tool)
    => tool.startsWith(MCP_PREFIX);

/// Reports whether the tool call reads the ping stream, which unread pings must not block.
bool readsPings(string tool, JSONValue input)
    => tool == MCP_PREFIX~"read_messages" && "source" in input.object &&
        input["source"].type == JSONType.string && input["source"].str == "pings";

/// Blocks the request while the session's profile has unread pings, writing the response when it does.
bool blockedByPings(
    string tool,
    JSONValue input,
    string session,
    Output output
)
{
    if (!session.length || readsPings(tool, input))
        return false;

    Profile profile;
    try
    {
        enforce(bus !is null, "Coordination is unavailable");
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

    if (profile is null || !bus.unreadPings(profile).length)
        return false;

    respond(output, JSONValue([
        "decision": JSONValue("block"),
        "reason": JSONValue("You have unread pings - read them first: call read_messages with source \"pings\"")
    ]));
    return true;
}

// TODO: SessionStart, UserPromptSubmit, and PostToolUse context injection (profile briefing, unread
// dms, and pings) once the coordination MCP surfaces rooms and messages to agents.

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

    string session = "session_id" in data.object && data["session_id"].type == JSONType.string ?
        data["session_id"].str : null;
    if (blockedByPings(tool, input, session, output))
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

// TODO: Scheduler events supporting time, pings, dms, room messages, GitHub CLI, and Linear so agents
// can stop and then be able to start back up (apropos wait_for_message).

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
