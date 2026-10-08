module evals.session;

import evals : Eval, get, post, waitFor;

import core.time : seconds;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.json : JSONType, JSONValue;
import std.string : strip;
import std.uri : encodeComponent;

public:

class Sessions
{
private:
    string listing;
    string[] previous;
    string directory;
    string model;
    bool registered;

    string[] list()
    {
        string[] ret;
        foreach (entry; get(listing).array)
            ret ~= entry.str;

        return ret;
    }

    JSONValue launch(string prompt)
    {
        JSONValue ret = JSONValue.emptyObject;
        ret["prompt"] = JSONValue(prompt);
        ret["directory"] = JSONValue(directory);
        ret["model"] = JSONValue(model);
        return ret;
    }

public:
    this(string directory, string model)
    {
        this.directory = directory;
        this.model = model;
        listing = "/api/sessions?directory="~directory.encodeComponent;
        previous = list();
    }

    void run(Eval eval)
    {
        string reply = post("/api/print", launch("Reply only AUTONOM_READY. Do not use tools or modify files."))
            ["reply"].str;
        eval.check("print follows the reply instruction", reply.canFind("AUTONOM_READY"), reply.strip);
        string[] created;
        foreach (id; list())
        {
            if (!previous.canFind(id))
                created ~= id;
        }

        if (!eval.check("print creates exactly one session", created.length == 1, created.length.to!string))
            return;

        string session = "/api/sessions/"~created[0];
        post("/api/profiles", JSONValue(["name": JSONValue("eval")]), 201);
        post("/api/profiles/eval/session", JSONValue(["id": JSONValue(created[0])]));
        registered = true;
        post(session~"/start", launch(
            "Do not use tools. Begin with AUTONOM_RESUMED and explain merge sort in about 1000 words."
        ));
        if (!eval.check("resumed session comes online", waitFor(delegate bool()
        {
            return get(session)["status"].str == "online";
        }, 30.seconds)))
            return;

        post("/api/profiles/eval/session", JSONValue(["id": JSONValue("replacement-session")]), 409);
        eval.check("active session rejects profile replacement", true);
        post(session~"/stop");
        eval.check("stop releases process and lock", get(session)["status"].str == "offline");
        post(session~"/start", launch("Reply only AUTONOM_DONE. Do not use tools or modify files."));
        bool finished = waitFor(delegate bool()
        {
            return get(session)["exitStatus"].type != JSONType.null_;
        }, 120.seconds);
        JSONValue status = get(session);
        eval.check("resumed session exits cleanly", finished && status["exitStatus"] == JSONValue(0),
            status["exitStatus"].toString());
        eval.check("resumed reply is logged", get(session~"/log")["log"].str.canFind("AUTONOM_DONE"));
        eval.check("final status is offline", status["status"].str == "offline");
    }

    void close(Eval eval)
    {
        JSONValue ids = JSONValue.emptyArray;
        foreach (id; list())
        {
            if (!previous.canFind(id))
                ids.array ~= JSONValue(id);
        }

        JSONValue removed = post("/api/sessions/remove", JSONValue(["ids": ids]));
        eval.check("removes every eval-created session", removed["removed"] == ids, ids.toString());
        string[] remaining = list();
        bool restored = remaining.length == previous.length;
        foreach (id; remaining)
            restored = restored && previous.canFind(id);

        eval.check("session listing is restored after cleanup", restored, remaining.length.to!string);
        foreach (id; ids.array)
            get("/api/sessions/"~id.str~"/log", 404);

        eval.check("session logs are removed", true);
        if (registered)
            eval.check("profile association is cleared", get("/api/profiles/eval")["session"].type == JSONType.null_);
    }
}
