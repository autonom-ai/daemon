/// Read-only, transactional import of the two supported legacy profile formats.
module daemon.db.legacyprofiles;

import daemon.agent.store : validName;
import daemon.db : Connection;
import daemon.db.profiles : Profiles;
import daemon.exception : ConflictException;
import daemon.interop.session : SessionKey;
import daemon.storage : readText;

import arsd.sqlite : ResultSet;

import core.stdc.errno : errno, ENOENT;
import core.sys.posix.sys.stat : lstat, stat_t, S_ISDIR, S_ISREG;
import std.algorithm : sort;
import std.ascii : isWhite;
import std.exception : ErrnoException;
import std.file : DirEntry, SpanMode, dirEntries;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath;
import std.string : toLower, toStringz;

private struct LegacyProfiles
{
    int sourceVersion;
    string[string] assignments;
    string[string] bindings;
}

/// Import profiles once from a quiesced source. No source file is created, changed, or deleted.
/// This marker covers profiles only; it does not authorize a coupled production-store cutover.
bool importProfiles(Connection connection, string directory)
{
    directory = buildNormalizedPath(absolutePath(directory));
    bool ret;
    connection.transaction({
        ResultSet marker = connection.query("select source from imports where domain = ?", "profiles");
        scope(exit)
            destroy(marker);
        if (!marker.empty)
        {
            if (marker.front["source"] != directory)
                throw new ConflictException("Profiles were already imported from a different source");
            return;
        }
        if (new Profiles(connection).list().length)
            throw new ConflictException("Profile import requires an empty destination");

        LegacyProfiles data = readProfiles(directory);
        string[] names = data.bindings.keys;
        names.sort();
        foreach (name; names)
        {
            connection.query("insert into profiles(name) values (?)", name);
            connection.query("insert into profile_bindings(profile_name) values (?)", name);
        }
        Profiles profiles = new Profiles(connection);
        string[] ids = data.assignments.keys;
        ids.sort();
        foreach (id; ids)
            profiles.retainEntry(data.assignments[id], SessionKey("devin", id));
        foreach (name; names)
        {
            string id = data.bindings[name];
            if (id.length)
            {
                connection.query("update profile_bindings set provider = ?, session_id = ? where profile_name = ?",
                    "devin", id, name);
            }
        }
        connection.query("insert into imports(domain, source_version, source) values (?, ?, ?)",
            "profiles", data.sourceVersion, directory);
        ret = true;
    });
    return ret;
}

private LegacyProfiles readProfiles(string directory)
{
    LegacyProfiles ret;
    if (!legacyExists(directory, true))
        return ret;

    string path = buildPath(directory, "state.json");
    if (legacyExists(path))
    {
        JSONValue data = readObject(path);
        if (data.object.length != 3 || "version" !in data.object || data["version"] != JSONValue(1) ||
            "assignments" !in data.object || data["assignments"].type != JSONType.object ||
            "bindings" !in data.object || data["bindings"].type != JSONType.object)
            throw new Exception("Unsupported or malformed legacy profile state");

        ret.sourceVersion = 1;
        ret.assignments = readAssignments(data["assignments"]);
        foreach (name, value; data["bindings"].object)
        {
            if (name != canonicalName(name) || (value.type != JSONType.string && !value.isNull))
                throw new Exception("Invalid legacy profile binding");
            if (!legacyExists(buildPath(directory, name), true))
                throw new Exception("Legacy profile directory is unavailable");

            ret.bindings[name.idup] = value.isNull ? null : value.str.idup;
        }
    }
    else
    {
        path = buildPath(directory, "sessions.json");
        if (legacyExists(path))
            ret.assignments = readAssignments(readObject(path));
        foreach (DirEntry entry; dirEntries(directory, SpanMode.shallow))
        {
            if (entry.isSymlink)
                throw new Exception("Legacy profile storage contains a symlink");
            if (!entry.isDir)
                continue;

            string name = entry.name.baseName;
            if (name != canonicalName(name))
                throw new Exception("Invalid legacy profile directory");

            ret.bindings[name.idup] = null;
            path = buildPath(directory, name, "session.json");
            if (!legacyExists(path))
                continue;

            JSONValue data = readObject(path);
            if ("session_id" !in data.object || data["session_id"].type != JSONType.string)
                throw new Exception("Invalid legacy profile session");

            ret.bindings[name] = data["session_id"].str.idup;
        }
    }
    foreach (id, name; ret.assignments)
    {
        if (name !in ret.bindings)
            throw new Exception("Legacy association refers to a missing profile");
    }
    foreach (name, id; ret.bindings)
    {
        if (!id.length)
            continue;

        SessionKey key = SessionKey("devin", id);
        if (key.id !in ret.assignments || ret.assignments[key.id] != name)
            throw new Exception("Legacy current binding has no matching association");
    }
    return ret;
}

/// lstat-based presence check: absent is false, while symlinks and wrong types throw.
private bool legacyExists(string path, bool directory = false)
{
    stat_t attributes;
    if (lstat(path.toStringz, &attributes) != 0)
    {
        if (errno == ENOENT)
            return false;
        throw new ErrnoException("Could not inspect the legacy profile source");
    }
    if (directory ? !S_ISDIR(attributes.st_mode) : !S_ISREG(attributes.st_mode))
        throw new Exception("Legacy profile storage must be a real "~
            (directory ? "directory" : "file"));
    return true;
}

private string[string] readAssignments(JSONValue data)
{
    string[string] ret;
    foreach (id, name; data.object)
    {
        SessionKey key = SessionKey("devin", id);
        if (name.type != JSONType.string)
            throw new Exception("Invalid legacy profile association");

        ret[key.id] = canonicalName(name.str);
    }
    return ret;
}

private string canonicalName(string name)
{
    if (!validName(name) || name.toLower == "human")
        throw new Exception("Invalid or reserved legacy profile name");
    return name.toLower.idup;
}

private JSONValue readObject(string path)
{
    string content = readText(path);
    JSONValue ret = parseJSON(content, 32, JSONOptions.strictParsing);
    if (ret.type != JSONType.object)
        throw new Exception("Legacy profile records must be JSON objects");

    // std.json collapses duplicate object keys, so reject them before using the parsed map.
    bool[string][] objects;
    size_t offset;
    while (offset < content.length)
    {
        char character = content[offset];
        if (character == '{')
            objects ~= cast(bool[string])null;
        else if (character == '}')
            objects.length--;
        else if (character == '"')
        {
            size_t start = offset++;
            while (content[offset] != '"')
            {
                if (content[offset] == '\\')
                    offset++;
                offset++;
            }
            size_t next = offset + 1;
            while (next < content.length && isWhite(content[next]))
                next++;
            if (next < content.length && content[next] == ':')
            {
                string key = parseJSON(content[start..offset + 1], JSONOptions.strictParsing).str;
                if (key in objects[$-1])
                    throw new Exception("Duplicate legacy JSON member");
                objects[$-1][key] = true;
            }
        }
        offset++;
    }
    return ret;
}
