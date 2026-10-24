module daemon.interop.mcp;

import std.json : JSONType, JSONValue;

/// Name of the session-scoped coordination MCP server.
enum mcpServerName = "autonom-coord";

/// Build the MCP launch entry without forwarding operator or run authority.
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

/// Replace the coordination entry while preserving unrelated MCP servers.
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
