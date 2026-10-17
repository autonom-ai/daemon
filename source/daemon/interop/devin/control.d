module daemon.interop.devin.control;

import daemon.exception;
import daemon.interop.acp;
import daemon.interop.call : Call, CallResult;
import daemon.interop.devin.options : optionParams, promptParams;

import core.stdc.errno : errno, EAGAIN, EINTR, EWOULDBLOCK;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.json : JSONType, JSONValue, parseJSON;
import std.socket : AddressFamily, Socket, SocketOption, SocketOptionLevel, SocketOSException, SocketType, UnixAddress;
import std.uuid : randomUUID;

CallResult runControl(
    Call execution,
    string socketPath,
    string token,
    string sessionId,
    string prompt,
    string model,
    string mode
)
{
    if (mode.length)
    {
        controlRequest(socketPath, token, "session/set_config_option",
            optionParams(sessionId, "mode", mode), execution);
    }
    if (model.length)
    {
        controlRequest(socketPath, token, "session/set_config_option",
            optionParams(sessionId, "model", model), execution);
    }

    JSONValue result = controlRequest(socketPath, token, "session/prompt",
        promptParams(sessionId, prompt), execution);

    string reason = "stopReason" in result.object && result["stopReason"].type == JSONType.string
        ? result["stopReason"].str
        : null;
    CallResult ret;
    if (reason == "cancelled")
        ret.cancelled = true;
    else if (reason != "end_turn")
        ret.error = "Agent stopped: "~(reason.length ? reason : "unknown");

    return ret;
}

JSONValue controlRequest(
    string socketPath,
    string token,
    string method,
    JSONValue params,
    Call execution = null,
    Duration limit = Duration.zero
)
{
    Socket connection = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    scope(exit)
        connection.close();
    connection.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO,
        limit > Duration.zero ? limit : 2.seconds);

    try
        connection.connect(new UnixAddress(socketPath));
    catch (SocketOSException error)
        throw new BackendException("Could not reach the owning relay: "~error.msg);

    string id = randomUUID().toString();
    JSONValue request = JSONValue([
        "token": JSONValue(token),
        "id": JSONValue(id),
        "method": JSONValue(method),
        "params": params
    ]);
    sendLine(connection, request.toString());

    MonoTime deadline = execution is null
        ? MonoTime.currTime + 60.seconds
        : MonoTime.currTime + execution.timeout;
    if (limit > Duration.zero)
        deadline = MonoTime.currTime + limit;
    bool cancelling;
    connection.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 100.msecs);
    string reply;
    ubyte[8192] buffer;
    while (MonoTime.currTime < deadline)
    {
        if (!cancelling && execution !is null && execution.stopped && method != "session/cancel")
        {
            cancelling = true;
            try
            {
                controlRequest(socketPath, token, "session/cancel",
                    JSONValue(["sessionId": params["sessionId"]]), null);
            }
            catch (Exception)
            { }

            deadline = MonoTime.currTime + 30.seconds;
        }

        immutable ptrdiff_t count = connection.receive(buffer);
        if (count == Socket.ERROR)
        {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            {
                if (MonoTime.currTime >= deadline)
                    throw new BackendException("Relay control request timed out");

                continue;
            }

            throw new BackendException("Relay control request failed");
        }

        if (count == 0)
            throw new BackendException("Relay control connection closed");

        foreach (byte val; buffer[0..count])
        {
            if (val == '\n')
            {
                JSONValue parsed;
                try
                    parsed = parseJSON(reply);
                catch (Exception)
                    throw new BackendException("Invalid relay control reply");

                if ("id" in parsed.object && parsed["id"].type == JSONType.string &&
                    parsed["id"].str == id)
                {
                    if ("error" in parsed.object && !parsed["error"].isNull)
                    {
                        JSONValue error = parsed["error"];
                        int code = "code" in error.object && error["code"].type == JSONType.integer
                            ? cast(int)error["code"].integer
                            : -32603;
                        string message = "message" in error.object && error["message"].type == JSONType.string
                            ? error["message"].str
                            : "Agent request failed";
                        if (code == -32602)
                            throw new InvalidInputException(message);
                        if (code == -32015 || code == -32002)
                            throw new ConflictException(message);
                        throw new BackendException(message);
                    }

                    return "result" in parsed.object ? parsed["result"] : JSONValue(null);
                }
            }
            else
            {
                if (reply.length >= frameLimit)
                    throw new BackendException("ACP control reply exceeds the frame limit");
                reply ~= cast(char)val;
            }
        }

        if (MonoTime.currTime >= deadline)
            throw new BackendException("Relay control request timed out");

        Thread.sleep(10.msecs);
    }
    throw new BackendException("Relay control request timed out");
}

void sendLine(Socket connection, string line)
{
    ubyte[] bytes = cast(ubyte[])(line~"\n");
    size_t offset;
    while (offset < bytes.length)
    {
        immutable ptrdiff_t sent = connection.send(bytes[offset..$]);
        if (sent <= 0)
            throw new BackendException("Could not write to relay control socket");

        offset += sent;
    }
}
