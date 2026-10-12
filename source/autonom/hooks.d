module autonom.hooks;

import autonom.agent;
import autonom.events.event : Event, EventType;
import autonom.exception;
import autonom.interop.session;
import autonom.policy;
import autonom.server;
import serverino;

import std.algorithm.searching : startsWith;
import std.array : join;
import std.conv : to;
import std.json : JSONValue, JSONType;

private:

enum MCP_PREFIX = "mcp__autonom-coord__";
enum MAX_INJECTED_EVENTS = 5;

bool coordinationTool(string tool)
    => tool.startsWith(MCP_PREFIX);

bool readsEvents(string tool)
    => tool == MCP_PREFIX~"read_events";

JSONValue hookResponse()
    => JSONValue(cast(JSONValue[string])null);

JSONValue block(string reason)
    => JSONValue(["decision": JSONValue("block"), "reason": JSONValue(reason)]);

bool acceptHook(Request request, Output output, string event, out JSONValue data)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return false;
    }

    data = readBody(request);
    if ("hook_event_name" !in data.object || data["hook_event_name"].type != JSONType.string)
        throw new InvalidInputException("Expected a string hook_event_name");
    if (data["hook_event_name"].str != event)
        throw new InvalidInputException("Expected the "~event~" hook event");

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

string hookDirectory(JSONValue data, string session, Request request)
{
    if ("directory" in data.object && data["directory"].type == JSONType.string && data["directory"].str.length)
        return data["directory"].str;
    if ("cwd" in data.object && data["cwd"].type == JSONType.string && data["cwd"].str.length)
        return data["cwd"].str;
    if (request.get.has("directory") && request.get.read("directory").length)
        return request.get.read("directory");
    if (!session.length)
        return null;

    Session found = bridge.findSession(session);
    if (found !is null && found.execution !is null && found.execution.workspace.length)
        return found.execution.workspace;

    try
        return bridge.sessionMetadata(session).directory;
    catch (Exception)
        return null;
}

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
        respond(output, block("Profile access could not be verified"));
        return true;
    }

    if (profile is null || !events.unread(profile).length)
        return false;

    respond(output, block("You have unread events - read them first: call read_events"));
    return true;
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

string eventSummary(Event event)
{
    final switch (event.type)
    {
    case EventType.Ping:
        return "ping from "~event.from;

    case EventType.Room:
        return "room "~event.room~" from "~event.from;

    case EventType.DM:
        return "dm from "~event.from;

    case EventType.Clock:
        return "clock";
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
    if (blockedByEvents(tool, session, output))
        return;

    string directory = hookDirectory(data, session, request);
    if (blockedByPolicy(directory, tool, hookInput(data), output))
        return;

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

    respond(output, hookResponse());
}

@endpoint @route!"/api/hooks/permission-request"
void permissionRequest(Request request, Output output)
{
    respondHook!"PermissionRequest"(request, output);
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
