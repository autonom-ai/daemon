module evals.app;

import evals : Eval, request, waitFor;
import evals.policy : policyChecks;
import evals.session : sessionLifecycle;

import core.time : seconds;
import std.exception : enforce;
import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.net.curl : CurlException;
import std.path : buildPath;
import std.process : Config, environment, kill, Pid, spawnProcess, tryWait, wait;
import std.stdio : File, stderr, stdin, stdout;
import std.uuid : randomUUID;

public:

int main(string[] arguments)
{
    bool policy = arguments.length == 2 && arguments[1] == "--policy";
    if (arguments.length > 1 && !policy)
    {
        stderr.writeln("Usage: autonom-eval [--policy]");
        return 2;
    }

    if (policy && !environment.get("OPENROUTER_API_KEY").length)
    {
        stderr.writeln("Set OPENROUTER_API_KEY to run the policy eval");
        return 2;
    }

    string model = environment.get("AUTONOM_EVAL_MODEL");
    string workspace = environment.get("AUTONOM_EVAL_WORKSPACE");
    if (!policy && (!model.length || !workspace.length))
    {
        stderr.writeln("Set AUTONOM_EVAL_MODEL (for example SWE-2) and AUTONOM_EVAL_WORKSPACE (a trusted workspace)");
        return 2;
    }

    string root = buildPath(tempDir(), "autonom-eval-"~randomUUID().toString());
    mkdirRecurse(root);
    scope(exit)
        rmdirRecurse(root);

    string configuration = buildPath(root, "config.yml");
    write(configuration, "dataDir: data\ndevinCommand: "~
        JSONValue(environment.get("AUTONOM_EVAL_CLI", "devin")).toString()~"\n");
    File output = File(buildPath(root, "daemon.log"), "w");
    scope(exit)
        output.close();

    Pid daemon = spawnProcess(
        ["bin/autonom-daemon"],
        stdin,
        output,
        output,
        ["AUTONOM_CONFIG": configuration, "AUTONOM_PORT": "18080"],
        Config.retainStdin | Config.retainStdout | Config.retainStderr
    );
    scope(exit)
    {
        if (!tryWait(daemon).terminated)
        {
            kill(daemon);
            wait(daemon);
        }
    }

    Eval eval = new Eval(policy ? "policy screening via daemon" : "session lifecycle via daemon");
    try
    {
        enforce(waitFor(delegate bool()
        {
            enforce(!tryWait(daemon).terminated, readText(buildPath(root, "daemon.log")));
            try
                return request("/api/health")["status"].str == "ok";
            catch (CurlException)
                return false;
        }, 5.seconds), "Daemon did not become healthy");
        if (policy)
            policyChecks(eval, root);
        else
            sessionLifecycle(eval, workspace, model);

        request("/api/stop", "{}", 202);
        enforce(waitFor(delegate bool()
        {
            return tryWait(daemon).terminated;
        }, 5.seconds), "Daemon did not stop");
        eval.check("daemon stops cleanly", wait(daemon) == 0);
    }
    catch (Exception error)
        eval.check("completes without error", false, error.msg);

    eval.report(stdout);
    return eval.passed ? 0 : 1;
}
