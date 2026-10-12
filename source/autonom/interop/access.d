module autonom.interop.access;

import autonom.interop.execution;
import autonom.interop.session;
import autonom.storage;

import std.conv : octal;
import std.file;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.stdio : File;

public:

class Access
{
public:
    const string tokenPath;

    this(string directory)
    {
        if (exists(directory) && isSymlink(directory))
            throw new Exception("Access storage must not be a symlink");

        mkdirRecurse(directory);
        tokenPath = buildPath(directory, "client.token");
        managedPath = buildPath(directory, "managed.json");
        if (!exists(tokenPath))
            atomicWrite(tokenPath, secret());

        _clientToken = readText(tokenPath, 128);
        if (_clientToken.length != 64)
            throw new Exception("Invalid client capability");

        setAttributes(tokenPath, octal!"600");
        if (!exists(managedPath))
            return;

        JSONValue data = readJSON(managedPath);
        if (data.type != JSONType.object || "version" !in data.object || data["version"] != JSONValue(1) ||
            "sessions" !in data.object || data["sessions"].type != JSONType.object)
            throw new Exception("Invalid managed sessions");

        foreach (id, trusted; data["sessions"].object)
        {
            Session.validateId(id);
            if (trusted.type != JSONType.boolean)
                throw new Exception("Invalid managed session trust");

            sessions[id.idup] = trusted.boolean;
        }
    }

    string clientToken()
        => _clientToken;

    bool client(string token) const
        => equal(token, _clientToken);

    bool managed(string id) const
        => (id in sessions) !is null;

    bool trusted(string id) const
    {
        const(bool)* found = id in sessions;
        return found !is null && *found;
    }

    string[] ids()
        => sessions.keys;

    string begin(Execution execution)
    {
        string ret = secret();
        grants[ret] = execution;
        return ret;
    }

    Execution authenticate(string token, string session, bool bind = false)
    {
        if (!token.length || !session.length)
            return null;

        Execution* found = token in grants;
        if (found is null || !(*found).running || (*found).kind == ExecutionKind.Remove)
            return null;

        Execution ret = *found;
        bool started = ret.kind == ExecutionKind.Start || ret.kind == ExecutionKind.Print;
        if (!started && !managed(session))
            return null;
        if (!ret.sessionId.length)
        {
            if (!bind || !started)
                return null;

            ret.identify(session);
            remember(session, ret.trusted);
        }

        return ret.sessionId == session && managed(session) ? ret : null;
    }

    void remember(string id, bool trusted = false)
    {
        Session.validateId(id);
        if (id in sessions)
            return;

        sessions[id.idup] = trusted;
        save();
    }

    void forget(string id)
    {
        if (sessions.remove(id))
            save();
    }

    void collect()
    {
        foreach (token; grants.keys)
        {
            if (!grants[token].running)
                grants.remove(token);
        }
    }

private:
    string _clientToken;
    string managedPath;
    bool[string] sessions;
    Execution[string] grants;

    static bool equal(string left, string right) nothrow
    {
        if (left.length != right.length || !left.length)
            return false;

        uint difference;
        foreach (i, character; left)
            difference |= character ^ right[i];

        return difference == 0;
    }

    static string secret()
    {
        File source = File("/dev/urandom", "rb");
        scope(exit)
            source.close();

        ubyte[32] bytes;
        if (source.rawRead(bytes).length != bytes.length)
            throw new Exception("Could not generate a capability");

        string ret;
        foreach (value; bytes)
            ret ~= format("%02x", value);

        return ret;
    }

    void save()
    {
        JSONValue data = JSONValue.emptyObject;
        data["version"] = JSONValue(1);
        data["sessions"] = JSONValue.emptyObject;
        foreach (id, trusted; sessions)
            data["sessions"][id] = JSONValue(trusted);

        atomicWrite(managedPath, data.toString());
    }
}
