module evals.session;

import evals : Eval, request, waitFor;

import core.time : seconds;
import std.algorithm : canFind;
import std.conv : to;
import std.json : JSONType, JSONValue;
import std.net.curl : HTTP;
import std.string : strip;
import std.uri : encodeComponent;

public:

void sessionLifecycle(Eval eval, string workspace, string model)
{
    string listing = "/api/sessions?directory="~workspace.encodeComponent;
    bool[string] previous;
    foreach (entry; request(listing).array)
        previous[entry.str] = true;

    JSONValue launch = JSONValue([
        "prompt": JSONValue("Reply only AUTONOM_READY. Do not use tools or modify files."),
        "directory": JSONValue(workspace),
        "model": JSONValue(model)
    ]);
    string reply = request("/api/print", launch.toString())["reply"].str;
    eval.check("print follows the reply instruction", reply.canFind("AUTONOM_READY"), reply.strip);
    string[] created;
    foreach (entry; request(listing).array)
    {
        if (entry.str !in previous)
            created ~= entry.str;
    }

    if (!eval.check("print creates exactly one CLI session", created.length == 1, created.length.to!string~" new"))
        return;

    string session = "/api/sessions/"~created[0];
    scope(failure)
        request(
            session,
            null,
            200,
            HTTP.Method.del
        );

    request("/api/profiles", `{"name":"eval"}`, 201);
    request("/api/profiles/eval/session", JSONValue(["id": JSONValue(created[0])]).toString());
    launch["prompt"] = JSONValue("Reply only AUTONOM_RESUMED. Do not use tools or modify files.");
    request(session~"/start", launch.toString());
    eval.check("resumed session comes online", waitFor(delegate bool()
    {
        return request(session)["status"].str == "online";
    }, 30.seconds), request(session)["status"].str);
    request("/api/profiles/eval/session", `{"id":"replacement-session"}`, 409);
    eval.check("active session rejects profile replacement", true);
    request(session~"/stop", "{}");
    eval.check("stop releases the process and lock", request(session)["status"].str == "offline");
    launch["prompt"] = JSONValue("Reply only AUTONOM_DONE. Do not use tools or modify files.");
    request(session~"/start", launch.toString());
    bool finished = waitFor(delegate bool()
    {
        return request(session)["exitStatus"].type != JSONType.null_;
    }, 120.seconds);
    JSONValue status = request(session);
    eval.check("resumed session exits cleanly", finished && status["exitStatus"] == JSONValue(0),
        status["exitStatus"].toString());
    eval.check("resumed reply is logged", request(session~"/log")["log"].str.canFind("AUTONOM_DONE"));
    eval.check("final status is offline", status["status"].str == "offline", status["status"].str);
    request(
        session,
        null,
        200,
        HTTP.Method.del
    );
    bool removed = true;
    foreach (entry; request(listing).array)
        removed = removed && entry.str != created[0];

    request(session~"/log", null, 404);
    eval.check("removed session leaves the CLI and its log", removed);
}
