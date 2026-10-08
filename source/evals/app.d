module evals.app;

import evals : Eval;
import evals.daemon : Daemon;
import evals.policy : policyChecks;
import evals.session : Sessions;

import std.exception : enforce;
import std.process : environment;
import std.stdio : stderr, stdout;

private:

void finish(Eval eval, Daemon daemon, Sessions sessions)
{
    scope(exit)
        daemon.close();

    if (sessions !is null)
    {
        try
            sessions.close(eval);
        catch (Exception error)
            eval.check("session cleanup", false, error.msg);
    }

    try
    {
        daemon.stop();
        eval.check("daemon stops cleanly", true);
    }
    catch (Exception error)
        eval.check("daemon stops cleanly", false, error.msg);
}

void run(Eval eval, bool policy, bool sessions)
{
    Daemon daemon = new Daemon();
    Sessions lifecycle;
    scope(exit)
        finish(eval, daemon, lifecycle);

    if (policy)
        policyChecks(eval, daemon.workspace);
    if (sessions)
    {
        lifecycle = new Sessions(daemon.workspace, environment.get("AUTONOM_EVAL_MODEL", "swe-2-medium"));
        lifecycle.run(eval);
    }
}

public:

int main(string[] arguments)
{
    string selection = arguments.length > 1 ? arguments[1] : "--all";
    if (arguments.length > 2 || (selection != "--all" && selection != "--policy" && selection != "--sessions"))
    {
        stderr.writeln("Usage: autonom-eval [--all|--policy|--sessions]");
        return 2;
    }

    Eval eval = new Eval();
    try
    {
        enforce(selection == "--sessions" || environment.get("OPENROUTER_API_KEY").length,
            "Export OPENROUTER_API_KEY before running the policy eval");
        run(eval, selection != "--sessions", selection != "--policy");
    }
    catch (Exception error)
        eval.check("eval completes", false, error.msg);

    stdout.writeln(eval.passed ? "PASS live evals" : "FAIL live evals");
    return eval.passed ? 0 : 1;
}
