module autonom.interop.cleanup;

import autonom.exception : InvalidInput;
import autonom.interop.execution : Execution;
import autonom.interop.session : Session;
import autonom.server : acceptMethod, bridge, readBody, respond;
import serverino : Output, Request, endpoint, priority, route;

import std.exception : enforce;
import std.json : JSONType, JSONValue;

@priority(10) @endpoint @route!"/api/sessions/remove"
void removeSessions(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readBody(request);
    enforce!InvalidInput(data.object.length == 1 && "ids" in data.object, "Expected only the ids field");
    enforce!InvalidInput(data["ids"].type == JSONType.array, "Session IDs must be an array");
    bool[string] seen;
    foreach (id; data["ids"].array)
    {
        enforce!InvalidInput(id.type == JSONType.string, "Session IDs must be strings");
        enforce!InvalidInput(id.str !in seen, "Session IDs must be unique");
        Session.validateId(id.str);
        seen[id.str.idup] = true;
    }

    JSONValue ret = JSONValue.emptyObject;
    ret["ids"] = data["ids"];
    ret["executions"] = JSONValue.emptyArray;
    ret["failed"] = JSONValue.emptyArray;
    bool pending;
    foreach (id; data["ids"].array)
    {
        try
        {
            Execution execution = bridge.remove(id.str);
            ret["executions"].array ~= JSONValue(["id": JSONValue(execution.id), "sessionId": id]);
            pending = pending || execution.running;
        }
        catch (Exception)
            ret["failed"].array ~= id;
    }

    respond(output, ret, pending ? 202 : ret["failed"].array.length ? 503 : 200);
}
