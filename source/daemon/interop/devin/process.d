module daemon.interop.devin.process;

import daemon.interop.call : Call, CallResult;
import daemon.interop.process : createProcessGroup, terminate;
import daemon.storage : openFile;

import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDWR;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.json : JSONValue;
import std.process : Config, environment, Pid, spawnProcess, tryWait;
import std.stdio : File;

/// Prevent inherited Desktop routing from redirecting the Devin CLI back into ACP.
string[string] cliEnvironment(string database = null)
{
    string[string] ret = environment.toAA();
    ret.remove("ACP_BACKEND");
    if (database.length)
        ret["CHISEL_SESSION_DB"] = database;
    return ret;
}

CallResult removeSession(string command, Call call, string database = null)
{
    File output = openFile(call.outputPath, O_RDWR | O_CREAT | O_APPEND);
    File errors = openFile(call.errorPath, O_RDWR | O_CREAT | O_APPEND);
    File input = File("/dev/null", "r");
    scope(exit)
    {
        output.close();
        errors.close();
        input.close();
    }
    Config options = Config.newEnv | Config.retainStdin | Config.retainStdout | Config.retainStderr;
    options.preExecFunction = &createProcessGroup;
    Pid process = spawnProcess([command, "rm", "--force", "--", call.sessionId],
        input, output, errors, cliEnvironment(database), options);
    bool reaped;
    scope(exit)
    {
        if (!reaped)
            terminate(process, 1.seconds);
    }
    typeof(tryWait(Pid.init)) result;
    while (!(result = tryWait(process)).terminated)
    {
        if (call.stopped || MonoTime.currTime >= call.deadline ||
            output.size > 1024 * 1024 || errors.size > 1024 * 1024)
        {
            result.status = terminate(process, 1.seconds);
            result.terminated = true;
            break;
        }
        Thread.sleep(10.msecs);
    }
    reaped = true;
    CallResult ret;
    ret.cancelled = call.stopped;
    ret.exitStatus = JSONValue(result.status);
    if (MonoTime.currTime >= call.deadline)
        ret.error = "Session removal timed out";
    else if (result.status != 0)
        ret.error = "Session removal failed (exit "~result.status.to!string~")";
    return ret;
}
