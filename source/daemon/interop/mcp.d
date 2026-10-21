module daemon.interop.mcp;

import daemon.api;
import daemon.http;

import serverino;

import std.json : JSONType, JSONValue;

enum mcpServerName = "autonom-coord";

JSONValue coordServer(string port, string token)
{
    return JSONValue([
        "name": JSONValue(mcpServerName),
        "command": JSONValue("autonom"),
        "args": JSONValue([JSONValue("mcp")]),
        "env": JSONValue([
            JSONValue(["name": JSONValue("AUTONOM_PORT"), "value": JSONValue(port)]),
            JSONValue(["name": JSONValue("AUTONOM_MCP_TOKEN"), "value": JSONValue(token)]),
            JSONValue(["name": JSONValue("AUTONOM_RUN_TOKEN"), "value": JSONValue("")]),
            JSONValue(["name": JSONValue("AUTONOM_CLIENT_TOKEN"), "value": JSONValue("")])
        ])
    ]);
}

JSONValue injectCoord(JSONValue params, string port, string token)
{
    JSONValue[] servers;
    if ("mcpServers" in params.object && params["mcpServers"].type == JSONType.array)
    {
        foreach (entry; params["mcpServers"].array)
        {
            if (entry.type != JSONType.object || "name" !in entry.object ||
                entry["name"].type != JSONType.string || entry["name"].str != mcpServerName)
                servers ~= entry;
        }
    }

    servers ~= coordServer(port, token);
    params["mcpServers"] = JSONValue(servers);
    return params;
}

@endpoint @route!"/api/mcp/session"
void mcpSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    string session = bridge.access.mcpSession(request.header.read("x-autonom-mcp"));
    if (!session.length)
    {
        respondError(output, 403, "MCP capability is not bound to a session");
        return;
    }

    respond(output, JSONValue(["id": JSONValue(session)]));
}
