module autonom.session.devin.bridge;

import autonom.config : Config;
import autonom.session.bridge : Bridge;
import autonom.session.devin.session : DevinSession;

import std.algorithm : canFind;
import std.exception : enforce;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;

private:

enum string[] HOST_PREFIXES = [
    "ACP_",
    "ELECTRON_",
    "VSCODE_",
    "WINDSURF_"
];

public:

class Devin : Bridge
{
public:
    const string sessionLockDir;

    this(Config configuration)
    {
        super(configuration.devinCommand, buildPath(configuration.dataDir, "sessions"), HOST_PREFIXES);
        sessionLockDir = configuration.sessionLockDir;
    }

    static string[] arguments(string prompt, string model = null)
    {
        enforce(prompt.length && !prompt.canFind('\0'), "A prompt is required");
        enforce(!model.canFind('\0'), "Invalid model name");
        string[] ret = ["--print"];
        if (model.length)
            ret ~= ["--model", model];

        return ret~["--", prompt];
    }

    override DevinSession session(string id)
        => new DevinSession(id, this);

    override void remove(string id)
    {
        run(["rm", "--force", "--", id]);
    }

    string print(string prompt, string directory, string model = null)
        => run(arguments(prompt, model), directory);

    string[] list(string directory = null)
    {
        string[] ret;
        foreach (JSONValue entry; parseJSON(run(["list", "--format", "json"], directory)).array)
            ret ~= entry["id"].str;

        return ret;
    }
}
