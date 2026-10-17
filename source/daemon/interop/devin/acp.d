module daemon.interop.devin.acp;

import daemon.exception;
import daemon.interop.access : Access;
import daemon.interop.acp;
import daemon.interop.call : Call, CallResult;
import daemon.interop.mcp : injectCoord;
import daemon.interop.devin.process : cliEnvironment;
import daemon.interop.process;
import daemon.storage;

import core.stdc.errno : errno, EAGAIN, EINTR, EWOULDBLOCK;
import core.sync.mutex : Mutex;
import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDWR;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.json : JSONType, JSONValue, parseJSON;
import std.socket : AddressFamily, Socket, SocketOption, SocketOptionLevel, SocketOSException,
    SocketType, UnixAddress;
import std.stdio : File;
import std.uuid : randomUUID;

public:

enum REPLY_LIMIT = 1024 * 1024;

JSONValue sessionParams(string directory, string sessionId = null)
{
    JSONValue ret = JSONValue([
        "cwd": JSONValue(directory),
        "mcpServers": JSONValue.emptyArray,
        "_meta": JSONValue(["autonom/connector": JSONValue("autonom")])
    ]);
    if (sessionId.length)
        ret["sessionId"] = JSONValue(sessionId);

    return ret;
}

JSONValue promptParams(string sessionId, string prompt)
    => JSONValue([
        "sessionId": JSONValue(sessionId),
        "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue(prompt)])])
    ]);

JSONValue optionParams(string sessionId, string configId, string value)
    => JSONValue([
        "sessionId": JSONValue(sessionId),
        "configId": JSONValue(configId),
        "value": JSONValue(value)
    ]);

string normalizeMode(string mode)
{
    switch (mode)
    {
    case "":
        return null;
    case "dangerous":
    case "autonomous":
        return "bypass";
    case "auto":
    case "normal":
        return "ask";
    case "code":
        return "accept-edits";
    case "accept-edits":
    case "smart":
    case "ask":
    case "plan":
    case "bypass":
        return mode;
    default:
        throw new InvalidInputException("Invalid permission mode");
    }
}

CallResult runAcp(
    Call execution,
    string command,
    string directory,
    string sessionId,
    string prompt,
    string model,
    string mode,
    string runToken,
    string port,
    string dataDir,
    Access access,
    bool compactFirst = false
)
{
    string[string] child = cliEnvironment();
    child.remove("AUTONOM_CLIENT_TOKEN");
    child["AUTONOM_DATA_DIR"] = dataDir;
    if (runToken.length)
        child["AUTONOM_RUN_TOKEN"] = runToken;

    File output = openFile(execution.outputPath, O_RDWR | O_CREAT | O_APPEND);
    File errors = openFile(execution.errorPath, O_RDWR | O_CREAT | O_APPEND);
    scope(exit)
    {
        output.close();
        errors.close();
    }

    AcpClient agent = new AcpClient([command, "acp"], child, directory, errors);
    execution.connection = agent;
    scope(exit)
        agent.close();

    string reply;
    size_t written;
    bool live;
    string bound;
    Mutex replyMutex = new Mutex();
    agent.notification = (JSONValue message) {
        synchronized (replyMutex)
        {
            if (!live || "params" !in message.object)
                return;

            JSONValue params = message["params"];
            if ("sessionId" !in params.object || params["sessionId"].type != JSONType.string ||
                params["sessionId"].str != bound || "update" !in params.object)
                return;

            JSONValue update = params["update"];
            if (update.type != JSONType.object ||
                "sessionUpdate" !in update.object || update["sessionUpdate"].str != "agent_message_chunk" ||
                "content" !in update.object || update["content"].type != JSONType.object ||
                "text" !in update["content"].object || update["content"]["text"].type != JSONType.string)
                return;

            string text = update["content"]["text"].str;
            if (reply.length + text.length > REPLY_LIMIT)
                text = text[0..REPLY_LIMIT - reply.length];
            if (!text.length)
                return;

            reply ~= text;
            if (written < REPLY_LIMIT)
            {
                output.rawWrite(cast(ubyte[])text);
                written += text.length;
            }
        }
    };

    agent.request("initialize", JSONValue([
        "protocolVersion": JSONValue(1),
        "clientCapabilities": JSONValue([
            "fs": JSONValue([
                "readTextFile": JSONValue(false),
                "writeTextFile": JSONValue(false)
            ]),
            "terminal": JSONValue(false)
        ]),
        "clientInfo": JSONValue(["name": JSONValue("autonom"), "version": JSONValue("1")])
    ]), 30.seconds);

    string mcpToken = access.mint();
    JSONValue created;
    if (sessionId.length)
    {
        created = agent.request("session/load", injectCoord(sessionParams(directory, sessionId), port, mcpToken), 60.seconds);
        if ("sessionId" in created.object && created["sessionId"].str != sessionId)
            throw new Exception("Agent loaded a different session");
    }
    else
    {
        created = agent.request("session/new", injectCoord(sessionParams(directory), port, mcpToken), 60.seconds);
        if ("sessionId" !in created.object || created["sessionId"].type != JSONType.string)
            throw new Exception("Agent did not return a session");

        execution.identify(created["sessionId"].str);
    }

    bound = execution.sessionId;
    access.admitMcp(mcpToken, bound);
    applyOptions(agent, created, bound, model, mode);

    bool compacting = compactFirst;
    bool accepting = !compacting;
    synchronized (replyMutex)
        live = !compacting;
    long[] pending = [agent.send("session/prompt", promptParams(bound, compacting ? "/compact" : prompt))];
    execution.markSteerable(accepting);

    bool[long] steered;
    MonoTime deadline = execution.expiresAt;
    bool cancelled;
    bool failed;
    string failure;
    MonoTime cancelDeadline;
    while (pending.length || compacting || accepting)
    {
        if (!pending.length && compacting)
        {
            if (failed || cancelled || execution.stopped)
                break;

            compacting = false;
            synchronized (replyMutex)
                live = true;
            pending ~= agent.send("session/prompt", promptParams(bound, prompt));
            accepting = true;
            execution.markSteerable();
        }

        string[] queued;
        if (accepting)
        {
            if (pending.length)
                queued = execution.takeSteering();
            else
            {
                queued = execution.closeSteering();
                accepting = false;
            }
        }

        foreach (promptText; queued)
        {
            try
            {
                long sent = agent.send("session/prompt", promptParams(bound, promptText));
                pending ~= sent;
                steered[sent] = true;
            }
            catch (Exception)
            {
                execution.steerDone();
                break;
            }
        }
        if (!pending.length)
            break;

        foreach (i, id; pending)
        {
            JSONValue result;
            int code;
            string error;
            if (!agent.poll(id, result, code, error))
                continue;

            pending = pending[0..i]~pending[i + 1..$];
            if (id in steered)
            {
                steered.remove(id);
                execution.steerDone();
            }
            if (error.length)
            {
                if (!failed)
                    failure = error;
                failed = true;
                break;
            }

            string reason = "stopReason" in result.object && result["stopReason"].type == JSONType.string ?
                result["stopReason"].str : null;
            if (reason == "cancelled")
                cancelled = true;
            else if (reason != "end_turn")
            {
                failed = true;
                if (!failure.length)
                    failure = "Agent stopped: "~(reason.length ? reason : "unknown");
            }

            break;
        }

        if (execution.stopped && !cancelled && cancelDeadline == MonoTime.init)
        {
            try
                agent.notify("session/cancel", JSONValue(["sessionId": JSONValue(bound)]));
            catch (Exception)
            {
            }

            cancelDeadline = MonoTime.currTime + 10.seconds;
        }

        if (cancelDeadline != MonoTime.init && MonoTime.currTime >= cancelDeadline)
            break;
        if (MonoTime.currTime >= deadline && !failed)
        {
            failed = true;
            failure = "Agent turn timed out";
            try
                agent.notify("session/cancel", JSONValue(["sessionId": JSONValue(bound)]));
            catch (Exception)
            {
            }

            Thread.sleep(500.msecs);
            break;
        }
        Thread.sleep(10.msecs);
    }

    execution.markSteerable(false);
    agent.close();
    CallResult ret;
    ret.reply = reply;
    ret.exitStatus = JSONValue(agent.exitStatus);
    if (cancelled || execution.stopped)
        ret.cancelled = true;
    if (failed && !ret.cancelled)
        ret.error = failure.length ? failure : "Agent turn failed";

    return ret;
}

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
        controlRequest(socketPath, token, "session/set_config_option",
            optionParams(sessionId, "mode", mode), execution);
    if (model.length)
        controlRequest(socketPath, token, "session/set_config_option",
            optionParams(sessionId, "model", model), execution);

    JSONValue result = controlRequest(socketPath, token, "session/prompt",
        promptParams(sessionId, prompt), execution);

    string reason = "stopReason" in result.object && result["stopReason"].type == JSONType.string ?
        result["stopReason"].str : null;
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

    MonoTime deadline = execution is null ? MonoTime.currTime + 60.seconds :
        MonoTime.currTime + execution.timeout;
    if (limit > Duration.zero)
        deadline = MonoTime.currTime + limit;
    bool cancelling;
    connection.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 100.msecs);
    string reply;
    ubyte[8192] buffer;
    for (;;)
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
            {
            }

            deadline = MonoTime.currTime + 30.seconds;
        }

        immutable count = connection.receive(buffer);
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

        foreach (byte value; buffer[0..count])
        {
            if (value == '\n')
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
                        int code = "code" in error.object && error["code"].type == JSONType.integer ?
                            cast(int)error["code"].integer : -32603;
                        string message = "message" in error.object && error["message"].type == JSONType.string ?
                            error["message"].str : "Agent request failed";
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
                if (reply.length >= FRAME_LIMIT)
                    throw new BackendException("ACP control reply exceeds the frame limit");
                reply ~= cast(char)value;
            }
        }

        if (MonoTime.currTime >= deadline)
            throw new BackendException("Relay control request timed out");

        Thread.sleep(10.msecs);
    }
}

private:

void sendLine(Socket connection, string line)
{
    ubyte[] bytes = cast(ubyte[])(line~"\n");
    size_t offset;
    while (offset < bytes.length)
    {
        immutable sent = connection.send(bytes[offset..$]);
        if (sent <= 0)
            throw new BackendException("Could not write to relay control socket");

        offset += sent;
    }
}

void applyOptions(AcpClient agent, JSONValue created, string sessionId, string model, string mode)
{
    string requestedMode = normalizeMode(mode);
    if (requestedMode.length)
    {
        validateOption(created, "mode", requestedMode);
        agent.request("session/set_config_option",
            optionParams(sessionId, "mode", requestedMode), 15.seconds);
    }
    if (model.length)
    {
        validateOption(created, "model", model);
        agent.request("session/set_config_option",
            optionParams(sessionId, "model", model), 15.seconds);
    }
}

void validateOption(JSONValue created, string configId, string value)
{
    if ("configOptions" !in created.object || created["configOptions"].type != JSONType.array)
        return;

    foreach (option; created["configOptions"].array)
    {
        if (option.type != JSONType.object || "id" !in option.object || option["id"].str != configId ||
            "options" !in option.object || option["options"].type != JSONType.array)
            continue;

        bool allowed;
        foreach (entry; option["options"].array)
        {
            if (entry.type == JSONType.object && "value" in entry.object && entry["value"].str == value)
                allowed = true;
        }

        if (!allowed)
            throw new InvalidInputException("Unsupported "~configId~" value");
    }
}
