module tests.http.coord;

import tests.common;
import tests.http.common;

import unit_threaded : Name, Serial, should;

import core.sys.linux.sys.file : flock, LOCK_EX;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.json : JSONValue;
import std.net.curl : HTTP;
import std.path : buildPath;
import std.process;
import std.stdio : File;

@Name("Daemon coordinates rooms and messages while unread events remain advisory") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    static foreach (name; ["marlow", "wren"])
        request("/api/profiles", 201, JSONValue(["name": JSONValue(name)]).toString());
    request("/api/profiles", 409, `{"name":"human"}`);
    request("/api/profiles/marlow/session", 200, `{"id":"session-1"}`);
    request("/api/profiles/wren/session", 200, `{"id":"session-2"}`);

    request("/api/rooms").array.length.should == 0;
    request("/api/rooms?session=missing", 409)["error"].str.should == "No profile is registered for this session";
    request("/api/rooms?session=session-1", 400, `{"name":"general","extra":true}`);
    JSONValue created = request("/api/rooms?session=session-1", 201, `{"name":"#General"}`);
    created["name"].str.should == "general";
    created["count"].integer.should == 0;
    created["lastTs"].should == JSONValue(null);
    request("/api/rooms?session=session-2").array.length.should == 1;
    request("/api/rooms/general?session=session-2")["unread"].integer.should == 0;

    JSONValue posted = request(
        "/api/rooms/general/messages?session=session-1",
        201,
        `{"text":"hello","ping":["wren"]}`
    );
    posted["from"].str.should == "marlow";
    posted["room"].str.should == "general";
    posted["pinged"].array[0].str.should == "wren";
    JSONValue read = request("/api/rooms/general/messages?session=session-2");
    read["source"].str.should == "room";
    read["room"].str.should == "general";
    read["messages"].array.length.should == 1;
    read["messages"].array[0]["text"].str.should == "hello";
    request("/api/rooms/general/messages?session=session-2")["messages"].array.length.should == 0;
    request("/api/messages?session=session-2&source=pings")["messages"].array.length.should == 1;
    request("/api/messages?session=session-2&source=pings")["messages"].array.length.should == 0;
    request("/api/messages?session=session-2&source=dms")["messages"].array.length.should == 0;
    request("/api/messages?session=session-2&source=bad", 400);
    request("/api/messages?session=session-2", 404, `{"to":"missing","text":"hi"}`);

    mkdirRecurse(fixture.config.sessionLockDir);
    File lock = File(buildPath(fixture.config.sessionLockDir, "session-2.lock"), "w+");
    scope(exit)
    {
        if (lock.isOpen)
            lock.close();
    }

    flock(lock.fileno, LOCK_EX).should == 0;
    hookSession(fixture, "session-2");
    mkdirRecurse(buildPath(fixture.root, ".devin"));
    write(buildPath(fixture.root, ".devin", "policy.yml"), "rules:\n  - action: allow\n");
    JSONValue gate = JSONValue([
        "hook_event_name": JSONValue("PreToolUse"),
        "session_id": JSONValue("session-2"),
        "tool_name": JSONValue("mcp__autonom-coord__read_events"),
        "tool_input": JSONValue.emptyObject
    ]);
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";
    gate["tool_name"] = JSONValue("exec");
    request("/api/hooks/pre-tool-use", 200, gate.toString()).object.length.should == 0;
    gate["tool_name"] = JSONValue("mcp__autonom-coord__post_message");
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";

    request("/api/messages?session=session-1", 201, `{"to":"wren","text":"ping","ping":["wren"]}`);
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";
    gate["tool_name"] = JSONValue("exec");
    request("/api/hooks/pre-tool-use", 200, gate.toString()).object.length.should == 0;
    JSONValue context = JSONValue([
        "hook_event_name": JSONValue("UserPromptSubmit"),
        "session_id": JSONValue("session-2"),
        "prompt": JSONValue("continue")
    ]);
    request("/api/hooks/user-prompt-submit", 200, context.toString())["hookSpecificOutput"]["additionalContext"].str
        .should == "You have 1 unread event - read them with read_events: ping from marlow.";
    context["hook_event_name"] = JSONValue("PostToolUse");
    context["tool_name"] = JSONValue("exec");
    context["tool_input"] = JSONValue(["command": JSONValue("git status")]);
    request("/api/hooks/post-tool-use", 200, context.toString())["hookSpecificOutput"]["additionalContext"].str
        .should == "You have 1 unread event - read them with read_events: ping from marlow.";
    context["session_id"] = JSONValue("session-1");
    request("/api/hooks/post-tool-use", 200, context.toString()).object.length.should == 0;
    gate["tool_name"] = JSONValue("mcp__autonom-coord__read_messages");
    gate["tool_input"] = JSONValue(["source": JSONValue("pings")]);
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";
    gate["tool_name"] = JSONValue("mcp__autonom-coord__read_events");
    gate["tool_input"] = JSONValue.emptyObject;
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";
    JSONValue pending = request("/api/events?session=session-2");
    pending["events"].array.length.should == 1;
    pending["events"].array[0]["type"].str.should == "ping";
    pending["events"].array[0]["text"].str.should == "ping";
    pending["events"].array[0]["schedule"].should == JSONValue(null);
    request("/api/events?session=session-2")["events"].array.length.should == 0;
    gate["tool_name"] = JSONValue("mcp__autonom-coord__post_message");
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";

    request("/api/messages?session=session-1", 201, `{"to":"wren","text":"again","ping":["wren"]}`);
    request("/api/messages?session=session-2&source=pings")["messages"].array.length.should == 2;
    request("/api/hooks/pre-tool-use", 200, gate.toString())["hookSpecificOutput"]["updatedInput"]["session_id"].str
        .should == "session-2";
    request("/api/rooms/general/messages?session=session-1", 201, `{"text":"no pings"}`)["pinged"].array.length
        .should == 0;

    request("/api/rooms/general/membership?session=session-2")["owner"].str.should == "marlow";
    request("/api/rooms/general/membership?session=session-2")["involved"].should == JSONValue(null);
    request("/api/rooms/general/membership?session=session-2", 404, `{"involved":["marlow"]}`);
    request("/api/rooms/general/membership?session=session-1", 200, `{"involved":["marlow"]}`)["involved"].array.length
        .should == 1;
    request("/api/rooms?session=session-2").array.length.should == 0;
    request("/api/rooms/general?session=session-2", 404);
    request("/api/rooms/general/messages?session=session-2", 404);
    request("/api/rooms/general/membership?session=session-1", 200, `{"involved":[]}`)["involved"].array.length
        .should == 0;
    request("/api/rooms/general/membership?session=session-1", 200, `{"involved":null}`)["involved"]
        .should == JSONValue(null);

    request("/api/rooms/general/admins?session=session-2", 404, `{"profile":"wren"}`);
    request(
        "/api/rooms/general/admins?session=session-1",
        200,
        `{"profile":"wren"}`
    )["admins"].array.length.should == 1;
    request(
        "/api/rooms/general/admins?session=session-1&profile=wren",
        200,
        null,
        "application/json",
        HTTP.Method.del
    )["admins"].array.length.should == 0;
    request("/api/rooms/general/admins?session=session-1", 404, `{"profile":"missing"}`);

    request("/api/rooms/general?session=session-2", 404, null, "application/json", HTTP.Method.del);
    request("/api/rooms/general?session=session-1", 200, null, "application/json", HTTP.Method.del)["name"].str
        .should == "general";
    request("/api/rooms?session=session-1").array.length.should == 0;
}
