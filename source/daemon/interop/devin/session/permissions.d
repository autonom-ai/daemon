module daemon.interop.devin.session.permissions;

import daemon.exception : BackendException, ConflictException, InvalidInputException;
import daemon.http;
import daemon.interop.acp : AcpException, permissions, decide;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.connection : observedSession, observedConnection, controlSocket;
import daemon.interop.devin.control : controlRequest;
import daemon.interop.devin.session : Session;
static import daemon.api;

import serverino;

import core.time : msecs;
import std.conv : to;
import std.json : JSONType, JSONValue;
import std.string : split;

JSONValue pendingPermissions(Bridge owner, string id, long requestId = 0)
{
    if (owner.observedSession(id))
    {
        return controlRequest(owner.controlSocket(owner.observedConnection(id)), owner.access.clientToken,
            "autonom/permissions", JSONValue([
                "sessionId": JSONValue(id),
                "id": JSONValue(requestId)
            ]), null, 250.msecs);
    }
    foreach (execution; owner.executions)
    {
        if (execution.running && execution.sessionId == id && execution.connection !is null)
            return execution.connection.permissions(id, requestId);
    }
    return JSONValue.emptyArray;
}

void decidePermission(Bridge owner, string id, long requestId, string option)
{
    try
    {
        if (owner.observedSession(id))
        {
            controlRequest(owner.controlSocket(owner.observedConnection(id)), owner.access.clientToken,
                "autonom/permission", JSONValue([
                    "sessionId": JSONValue(id),
                    "id": JSONValue(requestId),
                    "optionId": option.length ? JSONValue(option) : JSONValue(null)
                ]), null, 250.msecs);
            return;
        }
        foreach (execution; owner.executions)
        {
            if (execution.running && execution.sessionId == id && execution.connection !is null)
            {
                execution.connection.decide(id, requestId, option);
                return;
            }
        }
        throw new ConflictException("Permission request is no longer pending");
    }
    catch (AcpException error)
    {
        if (error.code == -32602)
            throw new InvalidInputException(error.msg);
        throw new ConflictException(error.msg);
    }
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/permissions")
void sessionPermissions(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;
    string id = routeParameter!"/api/sessions/<id>/permissions"(request);
    Session.validateId(id);
    if (request.method == Request.Method.Post)
    {
        JSONValue data = readBody(request);
        onlyFields(data, ["id", "optionId"]);
        if ("id" !in data.object || data["id"].type != JSONType.integer ||
            "optionId" !in data.object || (!data["optionId"].isNull && data["optionId"].type != JSONType.string))
            throw new InvalidInputException("Expected an integer request id and an offered optionId, or null to cancel");
        daemon.api.bridge.decidePermission(id, data["id"].integer, data["optionId"].isNull ? null : data["optionId"].str);
        respond(output, JSONValue.emptyObject);
    }
    else
    {
        long requestId;
        if (request.get.has("id"))
        {
            try
                requestId = request.get.read("id").to!long;
            catch (Exception)
                throw new InvalidInputException("Permission request id must be an integer");
        }
        respond(output, daemon.api.bridge.pendingPermissions(id, requestId));
    }
}

bool matchSessionPermissionWithReqId(const Request request)
{
    string[] parts = request.path.split("/");
    return parts.length == 6 && parts[1] == "api" && parts[2] == "sessions" &&
           parts[4] == "permissions" && parts[3].length > 0 && parts[5].length > 0;
}

@endpoint @route!matchSessionPermissionWithReqId
void sessionPermissionById(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;
    string[] parts = request.path.split("/");
    string id = parts[3];
    Session.validateId(id);
    long requestId;
    try
        requestId = parts[5].to!long;
    catch (Exception)
        throw new InvalidInputException("Permission request id must be an integer");

    if (request.method == Request.Method.Post)
    {
        JSONValue data = readBody(request);
        if ("id" in data.object && data["id"].type == JSONType.integer && data["id"].integer != requestId)
            throw new InvalidInputException("Request id mismatch between path and body");
        onlyFields(data, ["id", "optionId"]);
        if ("optionId" !in data.object || (!data["optionId"].isNull && data["optionId"].type != JSONType.string))
            throw new InvalidInputException("Expected an offered optionId, or null to cancel");
        daemon.api.bridge.decidePermission(id, requestId, data["optionId"].isNull ? null : data["optionId"].str);
        respond(output, JSONValue.emptyObject);
    }
    else
        respond(output, daemon.api.bridge.pendingPermissions(id, requestId));
}
