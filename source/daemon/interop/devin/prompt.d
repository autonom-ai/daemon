module daemon.interop.devin.prompt;

import daemon.interop.acp : AcpClient, deliver;
import daemon.interop.call : Call, CallResult;
import daemon.interop.devin.options : promptParams;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.json : JSONType, JSONValue;

class DeliveryDeferredException : Exception
{
    this(string message)
    {
        super(message);
    }
}

CallResult promptResult(JSONValue result)
{
    CallResult ret;
    ret.stopReason = "stopReason" in result.object && result["stopReason"].type == JSONType.string
        ? result["stopReason"].str
        : null;
    ret.cancelled = ret.stopReason == "cancelled";
    if (!ret.cancelled && ret.stopReason != "end_turn")
        ret.error = "Agent stopped: "~(ret.stopReason.length ? ret.stopReason : "unknown");

    return ret;
}

CallResult deliverPrompt(Call call, AcpClient connection, string session, string prompt)
{
    long request = connection.deliver(promptParams(session, prompt));
    MonoTime deadline = call.expiresAt;
    bool cancelling;
    while (MonoTime.currTime < deadline)
    {
        JSONValue result;
        int code;
        string error;
        bool interrupted;
        if (connection.poll(request, result, code, error, &interrupted))
        {
            if (!error.length)
                return promptResult(result);

            CallResult ret;
            ret.error = error;
            ret.interrupted = interrupted;
            return ret;
        }

        if (call.stopped && !cancelling)
        {
            connection.notify("session/cancel", JSONValue(["sessionId": JSONValue(session)]));
            cancelling = true;
            deadline = MonoTime.currTime + 10.seconds;
        }

        Thread.sleep(10.msecs);
    }

    CallResult ret;
    ret.error = "Automatic delivery timed out; outcome is uncertain";
    ret.interrupted = true;
    return ret;
}
