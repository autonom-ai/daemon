module evals.session;

import autonom.profilestore : ProfileConflict, ProfileStore;
import autonom.session : Devin, Session, SessionStatus;
import evals : Eval, waitFor;

import core.time : seconds;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, readText;
import std.path : buildPath;
import std.string : strip;

public:

void sessionLifecycle(Eval eval, Devin devin, ProfileStore store, string workspace, string model)
{
    bool[string] previous;
    foreach (id; devin.list(workspace))
        previous[id] = true;

    string reply = devin.print("Reply only AUTONOM_READY. Do not use tools or modify files.", workspace, model);
    eval.check("print follows the reply instruction", reply.canFind("AUTONOM_READY"), reply.strip);
    string[] created;
    foreach (id; devin.list(workspace))
    {
        if (id !in previous)
            created ~= id;
    }

    if (!eval.check("print creates exactly one CLI session", created.length == 1, created.length.to!string~" new"))
        return;

    Session session = store.register("eval", created[0]).session;
    scope(failure)
        session.remove();

    session.start("Reply only AUTONOM_RESUMED. Do not use tools or modify files.", workspace, model);
    eval.check("resumed session comes online", waitFor(delegate bool()
    {
        return session.isOnline();
    }, 30.seconds), session.inspect().to!string);
    bool rejected;
    try
        store.register("eval", "replacement-session");
    catch (ProfileConflict)
        rejected = true;

    eval.check("active session rejects profile replacement", rejected);
    session.stop();
    eval.check("stop releases the process and lock", !session.isRunning() && !session.isOnline());
    session.start("Reply only AUTONOM_DONE. Do not use tools or modify files.", workspace, model);
    bool finished = waitFor(delegate bool()
    {
        return !session.isRunning();
    }, 120.seconds);
    eval.check("resumed session exits cleanly", finished && session.exitStatus.get == 0,
        session.exitStatus.isNull ? "running" : "exit "~session.exitStatus.get.to!string);
    string log = buildPath(devin.logDir, session.id~".log");
    eval.check("resumed reply is logged", exists(log) && readText(log).canFind("AUTONOM_DONE"));
    eval.check("final status is offline", session.inspect() == SessionStatus.Offline,
        session.inspect().to!string);
    session.remove();
    eval.check("removed session leaves the CLI and its log",
        !devin.list(workspace).canFind(session.id) && !exists(log));
}
