module autonom.config;

import autonom.router;
import autonom.storage;
import intuit.router : IRouter;
import mir.algebraic_alias.yaml;
import mir.deser.yaml;

import core.time : Duration, hours, seconds;
import std.algorithm.searching : canFind;
import std.ascii : isDigit;
import std.conv : to;
import std.path;
import std.process : environment;

private:

string resolvePath(string path, string base)
    => buildNormalizedPath(absolutePath(expandTilde(path), base));

Duration parseDuration(string text, string name)
{
    if (!text.length)
        throw new Exception(name~" must be a duration such as 30m or 1h");

    long scale = 1;
    string digits = text;
    char unit = text[$ - 1];
    if (!isDigit(unit))
    {
        switch (unit)
        {
        case 's':
            break;

        case 'm':
            scale = 60;
            break;

        case 'h':
            scale = 3600;
            break;

        case 'd':
            scale = 86400;
            break;

        default:
            throw new Exception(name~" must be a duration such as 30m or 1h");
        }

        digits = text[0 .. $ - 1];
    }

    long value;
    try
        value = digits.to!long;
    catch (Exception)
        throw new Exception(name~" must be a duration such as 30m or 1h");

    if (value < 1)
        throw new Exception(name~" must be a positive duration");

    return (value * scale).seconds;
}

Duration readDuration(YamlAlgebraic value, string name)
{
    if (value.kind == YamlAlgebraic.Kind.integer)
    {
        long seconds = value.get!long;
        if (seconds < 1)
            throw new Exception(name~" must be a positive duration");

        return seconds.seconds;
    }

    if (value.kind != YamlAlgebraic.Kind.string)
        throw new Exception(name~" must be a duration such as 30m or 1h");

    return parseDuration(value.get!string, name);
}

public:

class Config
{
    string dataDir;
    string sessionLockDir;
    string sessionDatabase;
    string devinCommand;
    bool compactOnResume;
    Duration offlineStartAfter = 1.hours;
    Duration offlineCompactAfter = 1.hours;
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

            switch (key)
            {
            case "compactOnResume":
                if (pair.value.kind != YamlAlgebraic.Kind.boolean)
                    throw new Exception("compactOnResume must be true or false");

                compactOnResume = pair.value.get!bool;
                continue;

            case "offlineStartAfter":
                offlineStartAfter = readDuration(pair.value, key);
                continue;

            case "offlineCompactAfter":
                offlineCompactAfter = readDuration(pair.value, key);
                continue;

            default:
                break;
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
        sessionDatabase = buildPath(dirName(sessionLockDir), "sessions.db");
        if (devinCommand.canFind('/'))
            devinCommand = resolvePath(devinCommand, base);
    }
}
