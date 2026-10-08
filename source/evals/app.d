module evals.app;

import autonom.config : Config;
import autonom.profilestore : ProfileStore;
import autonom.session : Devin;
import evals : Eval;
import evals.session : sessionLifecycle;

import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import std.process : environment;
import std.stdio : stderr, stdout;
import std.uuid : randomUUID;

int main()
{
    string model = environment.get("AUTONOM_EVAL_MODEL");
    string workspace = environment.get("AUTONOM_EVAL_WORKSPACE");
    if (!model.length || !workspace.length)
    {
        stderr.writeln("Set AUTONOM_EVAL_MODEL (for example SWE-2) and AUTONOM_EVAL_WORKSPACE (a trusted workspace)");
        return 2;
    }

    string root = buildPath(tempDir(), "autonom-eval-"~randomUUID().toString());
    mkdirRecurse(root);
    scope(exit)
        rmdirRecurse(root);

    write(buildPath(root, "config.yml"), "dataDir: data\ndevinCommand: "~
        JSONValue(environment.get("AUTONOM_EVAL_CLI", "devin")).toString()~"\n");
    Config config = new Config(buildPath(root, "config.yml"));
    Devin devin = new Devin(config);
    Eval eval = new Eval("session lifecycle");
    try
        sessionLifecycle(eval, devin, new ProfileStore(config, devin), workspace, model);
    catch (Exception error)
        eval.check("completes without error", false, error.msg);

    eval.report(stdout);
    return eval.passed ? 0 : 1;
}
