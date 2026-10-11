module autonom.config;

import autonom.router;
import autonom.storage;
import intuit.router : IRouter;
import mir.algebraic_alias.yaml;
import mir.deser.yaml;

import std.algorithm.searching : canFind;
import std.exception : enforce;
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
        enforce(settings.kind == YamlAlgebraic.Kind.object, "Configuration must be a YAML mapping");
        bool[string] seen;
        foreach (pair; settings.object.pairs)
        {
            enforce(pair.key.kind == YamlAlgebraic.Kind.string, "Configuration setting names must be strings");
            string key = pair.key.get!string.idup;
            enforce(key !in seen, "Duplicate configuration setting: "~key);
            seen[key] = true;
            if (key == "router")
            {
                router = createRouter(pair.value);
                continue;
            }

            enforce(pair.value.kind == YamlAlgebraic.Kind.string, "Configuration settings must be strings");
            string value = pair.value.get!string.idup;
            enforce(value.length && !value.canFind('\0'), "Configuration settings must not be empty");
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

        enforce(devinCommand.length, "Configuration requires devinCommand");
        enforce(router !is null, "Configuration requires router");
        dataDir = resolvePath(dataDir, base);
        sessionLockDir = resolvePath(sessionLockDir, base);
        if (devinCommand.canFind('/'))
            devinCommand = resolvePath(devinCommand, base);
    }
}
