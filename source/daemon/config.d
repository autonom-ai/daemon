module daemon.config;

import daemon.storage;
import intuit.router : IRouter, OpenRouter;
import mir.algebraic_alias.yaml;
import mir.deser.yaml;

import core.time : Duration, hours, minutes, seconds;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.ascii : isDigit;
import std.conv : to;
import std.path;
import std.process : environment, thisProcessID;
import std.string : strip;

private:

string resolvePath(string path, string base)
    => buildNormalizedPath(absolutePath(expandTilde(path), base));

Duration parseDuration(string text, string name)
{
    if (!text.length)
        throw new Exception(name~" must be a duration such as 30m or 1h");

    long scale = 1;
    string digits = text;
    char unit = text[$-1];
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

        digits = text[0..$-1];
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

size_t readPositiveInteger(YamlAlgebraic value, string name)
{
    long integer;
    if (value.kind == YamlAlgebraic.Kind.integer)
        integer = value.get!long;
    else if (value.kind == YamlAlgebraic.Kind.string)
    {
        try
            integer = value.get!string.strip.to!long;
        catch (Exception)
            throw new Exception(name ~ " must be a positive integer");
    }
    else
        throw new Exception(name ~ " must be a positive integer");

    if (integer < 1)
        throw new Exception(name ~ " must be a positive integer");

    return cast(size_t)integer;
}

size_t readByteSize(YamlAlgebraic value, string name)
{
    if (value.kind == YamlAlgebraic.Kind.integer)
    {
        long bytes = value.get!long;
        if (bytes < 1)
            throw new Exception(name ~ " must be a positive byte size");

        return cast(size_t)bytes;
    }
    if (value.kind != YamlAlgebraic.Kind.string)
        throw new Exception(name ~ " must be a byte size such as 4MB or 16MiB");

    string text = value.get!string.strip;
    if (!text.length)
        throw new Exception(name ~ " must not be empty");

    size_t scale = 1;
    string digits = text;
    if (text.endsWith("GiB") || text.endsWith("gib")) { scale = 1024 * 1024 * 1024; digits = text[0..$-3].strip; }
    else if (text.endsWith("GB") || text.endsWith("gb")) { scale = 1000 * 1000 * 1000; digits = text[0..$-2].strip; }
    else if (text.endsWith("MiB") || text.endsWith("mib")) { scale = 1024 * 1024; digits = text[0..$-3].strip; }
    else if (text.endsWith("MB") || text.endsWith("mb")) { scale = 1000 * 1000; digits = text[0..$-2].strip; }
    else if (text.endsWith("KiB") || text.endsWith("kib")) { scale = 1024; digits = text[0..$-3].strip; }
    else if (text.endsWith("KB") || text.endsWith("kb")) { scale = 1000; digits = text[0..$-2].strip; }
    else if (text.endsWith("B") || text.endsWith("b")) { scale = 1; digits = text[0..$-1].strip; }

    long val;
    try
        val = digits.to!long;
    catch (Exception)
        throw new Exception(name ~ " must be a byte size such as 4MiB or 16MB");

    if (val < 1)
        throw new Exception(name ~ " must be a positive byte size");

    return cast(size_t)(val * scale);
}

IRouter createRouter(YamlAlgebraic settings)
{
    if (settings.kind != YamlAlgebraic.Kind.object)
        throw new Exception("Router configuration must be a mapping");

    string[string] values;
    foreach (pair; settings.object.pairs)
    {
        if (pair.key.kind != YamlAlgebraic.Kind.string)
            throw new Exception("Router setting names must be strings");

        string field = pair.key.get!string.idup;
        if (field in values)
            throw new Exception("Duplicate router setting: "~field);
        if (pair.value.kind != YamlAlgebraic.Kind.string)
            throw new Exception("Router settings must be strings");

        string value = pair.value.get!string.idup;
        if (value.canFind('\0'))
            throw new Exception("Invalid router setting");

        switch (field)
        {
        case "type", "key", "url", "name", "referer", "title":
            values[field] = value;
            break;

        default:
            throw new Exception("Unknown router setting: "~field);
        }
    }

    foreach (field; ["type", "key", "url", "name"])
    {
        if (field !in values || !values[field].length)
            throw new Exception("Router requires "~field);
    }

    string url = values["url"];
    if (!((url.startsWith("https://") && url.length > 8) ||
        (url.startsWith("http://") && url.length > 7)))
        throw new Exception("Router URL must use HTTP or HTTPS");

    if (values["type"] != "openrouter")
        throw new Exception("Unsupported router type");

    OpenRouter ret = new OpenRouter(values["key"], url, values["name"]);
    ret.referer = values.get("referer", null);
    ret.title = values.get("title", null);
    return ret;
}

public:

class Config
{
    string path;
    Duration executionTimeout = 30.minutes;
    string dataDir;
    string sessionLockDir;
    string sessionDatabase;
    string devinCommand;
    bool compactOnResume;
    Duration offlineStartAfter = 1.hours;
    Duration offlineCompactAfter = 1.hours;
    size_t maxStreamBytes = 4 * 1024 * 1024;
    size_t maxStreamEntries = 1000;
    size_t callCapacity = 128;
    Duration callSettleTimeout = 300.seconds;
    size_t maxConcurrentCalls = 8;
    bool pruneExecutionArtifacts;
    bool allowDestructivePruning;
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
        this.path = configPath;
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

            case "executionTimeout":
                executionTimeout = readDuration(pair.value, key);
                continue;

            case "offlineStartAfter":
                offlineStartAfter = readDuration(pair.value, key);
                continue;

            case "offlineCompactAfter":
                offlineCompactAfter = readDuration(pair.value, key);
                continue;

            case "callSettleTimeout":
                callSettleTimeout = readDuration(pair.value, key);
                continue;

            case "callCapacity":
                callCapacity = readPositiveInteger(pair.value, key);
                continue;

            case "maxStreamBytes":
                maxStreamBytes = readByteSize(pair.value, key);
                continue;

            case "maxStreamEntries":
                maxStreamEntries = readPositiveInteger(pair.value, key);
                continue;

            case "maxConcurrentCalls":
                maxConcurrentCalls = readPositiveInteger(pair.value, key);
                continue;

            case "pruneExecutionArtifacts":
                if (pair.value.kind != YamlAlgebraic.Kind.boolean)
                    throw new Exception("pruneExecutionArtifacts must be true or false");

                pruneExecutionArtifacts = pair.value.get!bool;
                continue;

            case "allowDestructivePruning":
                if (pair.value.kind != YamlAlgebraic.Kind.boolean)
                    throw new Exception("allowDestructivePruning must be true or false");

                allowDestructivePruning = pair.value.get!bool;
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
