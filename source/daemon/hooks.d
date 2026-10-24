module daemon.hooks;

import daemon.agent;
import daemon.api;
import daemon.events.event : Event;
import daemon.events.wake : adopt;
import daemon.exception;
import daemon.http;
import daemon.interop.call;
import daemon.interop.devin.connection;
import daemon.interop.devin.session.catalog;
import daemon.interop.session : Session;
import daemon.policy;

import serverino;

import std.algorithm.searching : startsWith;
import std.array : join;
import std.conv : to;
import std.json : JSONValue, JSONType;

private enum mcpPrefix = "mcp__autonom-coord__";
private enum maxInjectedEvents = 5;

private JSONValue hookResponse()
    => JSONValue(cast(JSONValue[string])null);

private JSONValue block(string reason)
    => JSONValue(["decision": JSONValue("block"), "reason": JSONValue(reason)]);

private bool acceptHook(Request request, Output output, string event, out JSONValue data)
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
            (hookTool(data).startsWith(mcpPrefix) || request.header.read("x-autonom-run").length ||
            bridge.access.managed(session));
        respond(output, blocked ? block("Only sessions started by Autonom may use Autonom tools") : hookResponse());
        return false;
    }

    if (execution.profileName.length && !profileStarts.bind(execution))
    {
        respond(output, event == "PreToolUse" ?
            block("The profile start is no longer current") : hookResponse());
        return false;
    }

    scheduler.adopt(session, execution.workspace, execution.id);
    return true;
}

private string hookSession(JSONValue data)
    => "session_id" in data.object && data["session_id"].type == JSONType.string ? data["session_id"].str : null;

private string hookTool(JSONValue data)
    => "tool_name" in data.object && data["tool_name"].type == JSONType.string ? data["tool_name"].str : null;

private JSONValue hookInput(JSONValue data)
{
    if ("tool_input" !in data.object)
        return JSONValue.emptyObject;
    if (data["tool_input"].type != JSONType.object)
        throw new InvalidInputException("Tool input must be an object");

    return data["tool_input"];
}

private string hookDirectory(JSONValue data, string session)
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

private bool blockedByPolicy(string directory, string tool, JSONValue input, Output output)
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

private string unreadContext(Profile profile)
{
    Event[] unread = events.unread(profile);
    if (!unread.length)
        return null;

    string[] listed;
    foreach (i, event; unread)
    {
        if (i == maxInjectedEvents)
        {
            listed ~= (unread.length - maxInjectedEvents).to!string~" more";
            break;
        }

        listed ~= event.summary;
    }

    return "You have "~unread.length.to!string~" unread event"~(unread.length == 1 ? "" : "s")~
        " - read them with read_events: "~listed.join("; ")~".";
}

private JSONValue contextResponse(string event, string session)
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

private void respondHook(string event)(Request request, Output output)
{
    JSONValue data;
    if (!acceptHook(request, output, event, data))
        return;

    respond(output, hookResponse());
}

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

    if (tool.startsWith(mcpPrefix) && session.length)
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
