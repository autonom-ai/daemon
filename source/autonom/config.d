module autonom.config;

import autonom.router;
import autonom.storage;
import intuit.router : IRouter;
import mir.algebraic_alias.yaml;
import mir.deser.yaml;

import std.algorithm.searching : canFind;
import std.path;
import std.process : environment;

private:

string resolvePath(string path, string base)
    => buildNormalizedPath(absolutePath(expandTilde(path), base));

public:

class Config
{
    string dataDir;
    string sessionLockDir;
    string devinCommand;
    IRouter router;

    static string defaultPath()
        => buildPath(environment.get("XDG_CONFIG_HOME", expandTilde("~/.config")), "autonom", "config.yml");

    static string defaultSessionLockDir()
        => buildPath(
            environment.get("XDG_DATA_HOME", expandTilde("~/.local/share")),
            "devin",
            "cli",
            "session_locks"
        );

    this(string path = defaultPath)
    {
        string configPath = buildNormalizedPath(absolutePath(expandTilde(path)));
        string base = dirName(configPath);
        dataDir = base;
        sessionLockDir = defaultSessionLockDir;
        YamlAlgebraic settings = readText(configPath).deserializeYaml!YamlAlgebraic(configPath);
        if (settings.kind != YamlAlgebraic.Kind.object)
            throw new Exception("Configuration must be a YAML mapping");

        bool[string] seen;
        foreach (pair; settings.object.pairs)
        {
            if (pair.key.kind != YamlAlgebraic.Kind.string)
                throw new Exception("Configuration setting names must be strings");

            string key = pair.key.get!string.idup;
            if (key in seen)
                throw new Exception("Duplicate configuration setting: "~key);

            seen[key] = true;
            if (key == "router")
            {
                router = createRouter(pair.value);
                continue;
            }

            if (pair.value.kind != YamlAlgebraic.Kind.string)
                throw new Exception("Configuration settings must be strings");

            string value = pair.value.get!string.idup;
            if (!value.length || value.canFind('\0'))
                throw new Exception("Configuration settings must not be empty");

            switch (key)
            {
            case "dataDir":
                dataDir = value;
                break;

            case "sessionLockDir":
                sessionLockDir = value;
                break;

            case "devinCommand":
                devinCommand = value;
                break;

            default:
                throw new Exception("Unknown configuration setting: "~key);
            }
        }

        if (!devinCommand.length)
            throw new Exception("Configuration requires devinCommand");
        if (router is null)
            throw new Exception("Configuration requires router");
        dataDir = resolvePath(dataDir, base);
        sessionLockDir = resolvePath(sessionLockDir, base);
        if (devinCommand.canFind('/'))
            devinCommand = resolvePath(devinCommand, base);
    }
}
