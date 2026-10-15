module daemon.interop.devin.acp;

import daemon.exception;
import daemon.interop.acp;
import daemon.interop.execution;
import daemon.interop.process;
import daemon.storage;

import core.stdc.errno : EAGAIN, EINTR, EWOULDBLOCK;
import core.sys.posix.fcntl : O_CREAT, O_EXCL, O_RDWR;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.json : JSONType, JSONValue, parseJSON;
import std.socket : AddressFamily, Socket, SocketOption, SocketOptionLevel, SocketOSException,
    SocketType, UnixAddress;
import std.stdio : File;
import std.uuid : randomUUID;

public:

enum REPLY_LIMIT = 1024 * 1024;

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

ExecutionTask acpTask(
    string command,
    string directory,
    string sessionId,
    string prompt,
    string model,
    string mode,
    string[string] environment,
    string runToken
)
{
    return (Execution execution) {
        string[string] child = childEnvironment();
        child.remove("AUTONOM_CLIENT_TOKEN");
        if (runToken.length)
            child["AUTONOM_RUN_TOKEN"] = runToken;
        foreach (name, value; environment)
            child[name] = value;

        File output = openFile(execution.outputPath, O_RDWR | O_CREAT | O_EXCL);
        File errors = openFile(execution.errorPath, O_RDWR | O_CREAT | O_EXCL);
        scope(exit)
        {
            output.close();
            errors.close();
        }

        AcpClient agent = new AcpClient([command, "acp"], child, directory, errors);
        scope(exit)
            agent.close();

        string reply;
        size_t written;
        bool live;
        string bound;
        agent.notification = (JSONValue message) {
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
        };
        agent.agentRequest = (JSONValue message) {
            if (message["method"].str == "session/request_permission")
            {
                JSONValue options = message["params"]["options"];
                string selected;
                if (options.type == JSONType.array)
                {
                    foreach (option; options.array)
                    {
                        if (option.type == JSONType.object && "kind" in option.object &&
                            option["kind"].str == "reject_once" && "optionId" in option.object)
                            selected = option["optionId"].str;
                    }
                }

                if (selected.length)
                    return JSONValue(["outcome": JSONValue([
                        "outcome": JSONValue("selected"),
                        "optionId": JSONValue(selected)
                    ])]);

                return JSONValue(["outcome": JSONValue(["outcome": JSONValue("cancelled")])]);
            }

            throw new AcpException(-32601, "Method not found");
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

        JSONValue created;
        if (sessionId.length)
        {
            created = agent.request("session/load", JSONValue([
                "sessionId": JSONValue(sessionId),
                "cwd": JSONValue(directory),
                "mcpServers": JSONValue.emptyArray
            ]), 60.seconds);
            if ("sessionId" in created.object && created["sessionId"].str != sessionId)
                throw new Exception("Agent loaded a different session");
        }
        else
        {
            created = agent.request("session/new", JSONValue([
                "cwd": JSONValue(directory),
                "mcpServers": JSONValue.emptyArray
            ]), 60.seconds);
            if ("sessionId" !in created.object || created["sessionId"].type != JSONType.string)
                throw new Exception("Agent did not return a session");

            execution.identify(created["sessionId"].str);
        }

        bound = execution.sessionId;
        applyOptions(agent, created, bound, model, mode);

        long[] pending = [
            agent.send("session/prompt", JSONValue([
                "sessionId": JSONValue(bound),
                "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue(prompt)])])
            ]))
        ];
        live = true;
        execution.markSteerable();

        bool[long] steered;
        MonoTime deadline = MonoTime.currTime + execution.timeout;
        bool cancelled;
        bool failed;
        string failure;
        MonoTime cancelDeadline;
        for (;;)
        {
            string[] queued = pending.length ? execution.takeSteering() : execution.closeSteering();
            foreach (promptText; queued)
            {
                try
                {
                    long sent = agent.send("session/prompt", JSONValue([
                        "sessionId": JSONValue(bound),
                        "prompt": JSONValue([JSONValue([
                            "type": JSONValue("text"),
                            "text": JSONValue(promptText)
                        ])])
                    ]));
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
            if (agent.disconnected)
            {
                if (!failed)
                {
                    failed = true;
                    failure = "Agent disconnected";
                }

                break;
            }

            Thread.sleep(10.msecs);
        }

        execution.markSteerable(false);
        agent.close();
        TaskResult ret;
        ret.reply = reply;
        ret.exitStatus = JSONValue(agent.exitStatus);
        if (cancelled || execution.stopped)
            ret.cancelled = true;
        if (failed && !ret.cancelled)
            ret.error = failure.length ? failure : "Agent turn failed";

        return ret;
    };
}

ExecutionTask controlTask(
    string socketPath,
    string token,
    string sessionId,
    string prompt,
    string model,
    string mode
)
{
    return (Execution execution) {
        if (mode.length || model.length)
        {
            if (mode.length)
                controlRequest(socketPath, token, "session/set_config_option", JSONValue([
                    "sessionId": JSONValue(sessionId),
                    "configId": JSONValue("mode"),
                    "value": JSONValue(mode)
                ]), execution);
            if (model.length)
                controlRequest(socketPath, token, "session/set_config_option", JSONValue([
                    "sessionId": JSONValue(sessionId),
                    "configId": JSONValue("model"),
                    "value": JSONValue(model)
                ]), execution);
        }

        JSONValue result = controlRequest(socketPath, token, "session/prompt", JSONValue([
            "sessionId": JSONValue(sessionId),
            "prompt": JSONValue([JSONValue(["type": JSONValue("text"), "text": JSONValue(prompt)])])
        ]), execution);

        string reason = "stopReason" in result.object && result["stopReason"].type == JSONType.string ?
            result["stopReason"].str : null;
        TaskResult ret;
        if (reason == "cancelled")
            ret.cancelled = true;
        else if (reason != "end_turn")
            ret.error = "Agent stopped: "~(reason.length ? reason : "unknown");

        return ret;
    };
}

JSONValue controlRequest(
    string socketPath,
    string token,
    string method,
    JSONValue params,
    Execution execution = null
)
{
    Socket connection = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    scope(exit)
        connection.close();

    try
        connection.connect(new UnixAddress(socketPath));
    catch (SocketOSException error)
        throw new BackendException("Could not reach the owning relay: "~error.msg);

    string id = ACP_INJECT_PREFIX~randomUUID().toString();
    JSONValue request = JSONValue([
        "token": JSONValue(token),
        "id": JSONValue(id),
        "method": JSONValue(method),
        "params": params
    ]);
    sendLine(connection, request.toString());

    MonoTime deadline = execution is null ? MonoTime.currTime + 60.seconds :
        MonoTime.currTime + execution.timeout;
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

        ptrdiff_t count;
        try
            count = connection.receive(buffer);
        catch (SocketOSException error)
        {
            if (error.errorCode == EAGAIN || error.errorCode == EWOULDBLOCK || error.errorCode == EINTR)
            {
                if (MonoTime.currTime >= deadline)
                    throw new BackendException("Relay control request timed out");

                continue;
            }

            throw new BackendException("Relay control request failed: "~error.msg);
        }

        if (count <= 0)
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
                        if (code == -32015)
                            throw new ConflictException(message);
                        throw new BackendException(message);
                    }

                    return "result" in parsed.object ? parsed["result"] : JSONValue(null);
                }
            }
            else
                reply ~= cast(char)value;
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
        agent.request("session/set_config_option", JSONValue([
            "sessionId": JSONValue(sessionId),
            "configId": JSONValue("mode"),
            "value": JSONValue(requestedMode)
        ]), 15.seconds);
    }
    if (model.length)
    {
        validateOption(created, "model", model);
        agent.request("session/set_config_option", JSONValue([
            "sessionId": JSONValue(sessionId),
            "configId": JSONValue("model"),
            "value": JSONValue(model)
        ]), 15.seconds);
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
