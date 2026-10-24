/// HTTP entry point for resolving a session-scoped MCP capability.
module daemon.mcp;

import daemon.api : bridge;
import daemon.http : acceptMethod, respond, respondError;

import serverino;

import std.json : JSONValue;

/// Return only the session bound to the supplied MCP capability.
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
