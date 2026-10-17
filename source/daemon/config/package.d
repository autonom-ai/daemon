module daemon.config;

public import daemon.config.parse;

import daemon.storage;
import intuit.router : IRouter;
import mir.algebraic_alias.yaml;
import mir.deser.yaml;

import core.time : Duration, hours, minutes, seconds;
import std.algorithm.searching : canFind;
import std.path;
import std.process : environment;

public:

class Config
{
private:
    static Config instance;

public:
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

    static Config get(string configPath = null)
    {
        if (instance !is null && configPath is null)
            return instance;

        string target = configPath.length ? configPath : environment.get("AUTONOM_CONFIG", defaultPath);
        string normalized = buildNormalizedPath(absolutePath(expandTilde(target)));
        if (instance is null || instance.path != normalized)
            instance = new Config(target);

        return instance;
    }

    static void set(Config conf)
    {
        instance = conf;
    }

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
