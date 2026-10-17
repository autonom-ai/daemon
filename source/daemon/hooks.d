module daemon.hooks;

import daemon.agent;
import daemon.events.event : Event;
import daemon.exception;
import daemon.interop.bridge;
import daemon.interop.session;
import daemon.policy;
import daemon.http;
import daemon.api;
import serverino;

import std.algorithm.searching : startsWith;
import std.array : join;
import std.conv : to;
import std.json : JSONValue, JSONType;

private:

enum MCP_PREFIX = "mcp__autonom-coord__";
enum MAX_INJECTED_EVENTS = 5;

JSONValue hookResponse()
    => JSONValue(cast(JSONValue[string])null);

JSONValue block(string reason)
    => JSONValue(["decision": JSONValue("block"), "reason": JSONValue(reason)]);

bool acceptHook(Request request, Output output, string event, out JSONValue data)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return false;

    data = readBody(request, 16 * 1024 * 1024);
    if ("hook_event_name" !in data.object || data["hook_event_name"].type != JSONType.string)
        throw new InvalidInputException("Expected a string hook_event_name");
    if (data["hook_event_name"].str != event)
        throw new InvalidInputException("Expected the "~event~" hook event");

    string session = hookSession(data);
    Call execution = bridge.authenticate(request.header.read("x-autonom-run"), session, true);
    if (execution is null)
    {
        string bound = bridge.access.mcpSession(request.header.read("x-autonom-mcp"));
        if (bound.length && bound == session)
            return true;

        bool blocked = event == "PreToolUse" &&
            (hookTool(data).startsWith(MCP_PREFIX) || request.header.read("x-autonom-run").length ||
            bridge.access.managed(session));
        respond(output, blocked ? block("Only sessions started by Autonom may use Autonom tools") : hookResponse());
        return false;
    }

    if (execution.profileName.length && profileStore.profileFor(session) is null)
        profileStore.register(execution.profileName, session);

    scheduler.adopt(session, execution.workspace, execution.id);
    return true;
}

string hookSession(JSONValue data)
    => "session_id" in data.object && data["session_id"].type == JSONType.string ? data["session_id"].str : null;

string hookTool(JSONValue data)
    => "tool_name" in data.object && data["tool_name"].type == JSONType.string ? data["tool_name"].str : null;

JSONValue hookInput(JSONValue data)
{
    if ("tool_input" !in data.object)
        return JSONValue.emptyObject;
    if (data["tool_input"].type != JSONType.object)
        throw new InvalidInputException("Tool input must be an object");

    return data["tool_input"];
}

string hookDirectory(JSONValue data, string session)
{
    if (!session.length)
        return null;

    Session found = bridge.findSession(session);
    if (found !is null && found.execution !is null && found.execution.workspace.length)
        return found.execution.workspace;

    string observed = bridge.observedDirectory(session);
    if (observed.length)
        return observed;

    try
        return bridge.sessionMetadata(session).directory;
    catch (Exception)
        return null;
}

bool blockedByPolicy(string directory, string tool, JSONValue input, Output output)
{
    if (!directory.length)
        return false;

    if (policy is null)
    {
        respond(output, block("Policy check is unavailable"));
        return true;
    }

    try
    {
        PolicyResult result = policy.check(directory, tool, input);
        if (!result.denied)
            return false;

        respond(output, block(result.reason.length ? result.reason : "Denied by workspace policy"));
        return true;
    }
    catch (Exception error)
    {
        respond(output, block("Policy check failed: "~error.msg));
        return true;
    }
}

string unreadContext(Profile profile)
{
    Event[] unread = events.unread(profile);
    if (!unread.length)
        return null;

    string[] listed;
    foreach (i, event; unread)
    {
        if (i == MAX_INJECTED_EVENTS)
        {
            listed ~= (unread.length - MAX_INJECTED_EVENTS).to!string~" more";
            break;
        }

        listed ~= event.summary;
    }

    return "You have "~unread.length.to!string~" unread event"~(unread.length == 1 ? "" : "s")~
        " - read them with read_events: "~listed.join("; ")~".";
}

JSONValue contextResponse(string event, string session)
{
    if (!session.length || events is null)
        return hookResponse();

    Profile profile;
    try
        profile = profileStore.profileFor(session);
    catch (Exception)
        return hookResponse();

    if (profile is null)
        return hookResponse();

    string context = unreadContext(profile);
    if (!context.length)
        return hookResponse();

    return JSONValue([
        "hookSpecificOutput": JSONValue([
            "hookEventName": JSONValue(event),
            "additionalContext": JSONValue(context)
        ])
    ]);
}

void respondHook(string EVENT)(Request request, Output output)
{
    JSONValue data;
    if (!acceptHook(request, output, EVENT, data))
        return;

    respond(output, hookResponse());
}

public:

@endpoint @route!"/api/hooks/pre-tool-use"
void preToolUse(Request request, Output output)
{
    JSONValue data;
    if (!acceptHook(request, output, "PreToolUse", data))
        return;

    string tool = hookTool(data);
    if (!tool.length)
    {
        respond(output, hookResponse());
        return;
    }

    string session = hookSession(data);
    string directory = hookDirectory(data, session);
    if (blockedByPolicy(directory, tool, hookInput(data), output))
        return;

    if (session.length && directory.length)
        scheduler.adopt(session, directory);

    if (tool.startsWith(MCP_PREFIX) && session.length)
    {
        respond(output, JSONValue([
            "hookSpecificOutput": JSONValue([
                "hookEventName": JSONValue("PreToolUse"),
                "updatedInput": JSONValue(["session_id": JSONValue(session)])
            ])
        ]));
        return;
    }
    respond(output, hookResponse());
}

@endpoint @route!"/api/hooks/permission-request"
void permissionRequest(Request request, Output output)
{
    JSONValue data;
    if (!acceptHook(request, output, "PermissionRequest", data))
        return;

    respond(output, hookResponse());
}

@endpoint @route!"/api/hooks/post-tool-use"
void postToolUse(Request request, Output output)
{
    JSONValue data;
    if (!acceptHook(request, output, "PostToolUse", data))
        return;

    respond(output, contextResponse("PostToolUse", hookSession(data)));
}

@endpoint @route!"/api/hooks/user-prompt-submit"
void userPromptSubmit(Request request, Output output)
{
    JSONValue data;
    if (!acceptHook(request, output, "UserPromptSubmit", data))
        return;

    respond(output, contextResponse("UserPromptSubmit", hookSession(data)));
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
