module daemon.interop.devin.hooks;

import daemon.storage : atomicWrite, openFile, readJSON, readText;

import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB;
import core.sys.posix.fcntl : O_CREAT, O_RDWR;
import std.algorithm.searching : canFind;
import std.file : exists, isFile, isSymlink, mkdirRecurse, thisExePath;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName, isAbsolute;
import std.process : environment;
import std.stdio : File;
import std.string : replace;

string globalConfigPath()
{
    string base = environment.get("XDG_CONFIG_HOME");
    if (!base.length)
    {
        string home = environment.get("HOME");
        if (!home.length)
            throw new Exception("Devin hook registration requires HOME or XDG_CONFIG_HOME");

        base = buildPath(home, ".config");
    }

    if (!isAbsolute(base))
        throw new Exception("Devin configuration directory must be absolute");

    return buildPath(base, "devin", "config.json");
}

private bool managed(JSONValue hook)
{
    if (hook.type != JSONType.object || "command" !in hook.object ||
        hook["command"].type != JSONType.string)
        return false;

    string command = hook["command"].str;
    return command.canFind("/source/daemon/interop/devin/hook.py") ||
        command.canFind("/source/coord/hook.py");
}

/// Preserve user entries, including commands sharing a matcher with Autonom.
JSONValue mergeHooks(JSONValue config, JSONValue rendered)
{
    if (config.type != JSONType.object || rendered.type != JSONType.object)
        throw new Exception("Devin configuration and hook template must be objects");

    JSONValue hooks = "hooks" in config.object ? config["hooks"] : JSONValue.emptyObject;
    if (hooks.type != JSONType.object)
        throw new Exception("Devin hooks must be an object");

    foreach (event, entries; hooks.object)
    {
        if (entries.type != JSONType.array)
            throw new Exception("Devin hook events must contain arrays");

        JSONValue kept = JSONValue.emptyArray;
        foreach (entry; entries.array)
        {
            if (entry.type != JSONType.object || "hooks" !in entry.object ||
                entry["hooks"].type != JSONType.array)
                throw new Exception("Invalid Devin hook entry");

            JSONValue commands = JSONValue.emptyArray;
            foreach (hook; entry["hooks"].array)
            {
                if (!managed(hook))
                    commands.array ~= hook;
            }

            if (commands.array.length || !entry["hooks"].array.length)
            {
                entry["hooks"] = commands;
                kept.array ~= entry;
            }
        }

        hooks[event] = kept;
    }

    foreach (event, entries; rendered.object)
    {
        if (event !in hooks.object)
            hooks[event] = JSONValue.emptyArray;

        foreach (entry; entries.array)
            hooks[event].array ~= entry;
    }

    config["hooks"] = hooks;
    return config;
}

/// Reconcile only Autonom commands; serialize against other Autonom processes.
void installHooks(string root = null, string path = null)
{
    if (!root.length)
        root = dirName(dirName(thisExePath));
    if (!path.length)
        path = globalConfigPath();

    string script = buildPath(root, "source", "daemon", "interop", "devin", "hook.py");
    if (!isFile(script) || isSymlink(script))
        throw new Exception("Autonom hook script is unavailable");

    JSONValue rendered = parseJSON(readText(buildPath(root, "devin", "hooks.v1.json")));
    // Replace inside each command so quotes and backslashes in paths stay JSON-safe.
    foreach (event, ref entries; rendered.object)
    {
        foreach (ref entry; entries.array)
        {
            foreach (ref hook; entry["hooks"].array)
            {
                string escaped = root.replace("\\", "\\\\").replace("\"", "\\\"")
                    .replace("$", "\\$").replace("`", "\\`");
                hook["command"] = JSONValue(hook["command"].str.replace("{{AUTONOM_ROOT}}", escaped));
            }
        }
    }

    mkdirRecurse(dirName(path));
    File lock = openFile(path~".autonom.lock", O_CREAT | O_RDWR);
    scope(exit)
        lock.close();

    if (flock(lock.fileno, LOCK_EX | LOCK_NB) != 0)
        throw new Exception("Devin hook registration is already in progress");

    JSONValue original = exists(path) ? readJSON(path, 1024 * 1024) : JSONValue.emptyObject;
    // JSONValue copies share arrays and objects; compare serialized snapshots.
    string previous = original.toString();
    JSONValue next = mergeHooks(original, rendered);
    if (previous != next.toString())
        atomicWrite(path, next.toPrettyString()~"\n");
}
