module daemon.interop.devin.acp;

import daemon.interop.access : Access;
import daemon.interop.acp;
import daemon.interop.call : Call, CallResult;
import daemon.interop.devin.options;
import daemon.interop.devin.process : cliEnvironment;
import daemon.interop.mcp : injectCoord;
import daemon.storage;

import core.sync.mutex : Mutex;
import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDWR;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.json : JSONType, JSONValue;
import std.stdio : File;

enum replyLimit = 1024 * 1024;

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
            if (reply.length + text.length > replyLimit)
                text = text[0..replyLimit - reply.length];
            if (!text.length)
                return;

            reply ~= text;
            if (written < replyLimit)
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
        "clientInfo": JSONValue(["name": JSONValue("autonom"),
        "version": JSONValue("1")])
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

            string reason = "stopReason" in result.object && result["stopReason"].type == JSONType.string
                ? result["stopReason"].str
                : null;
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
            { }

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
            { }

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
