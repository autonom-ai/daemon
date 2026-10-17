module daemon.interop.access;

import daemon.interop.call;
import daemon.interop.session;
import daemon.storage;

import core.sync.mutex : Mutex;
import std.algorithm : endsWith;
import std.conv : octal;
import std.file;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.path : baseName, buildPath;
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
        mcpDir = buildPath(directory, "mcp");
        if (exists(mcpDir) && (isSymlink(mcpDir) || !isDir(mcpDir)))
            throw new Exception("MCP credential storage must not be a symlink");

        mkdirRecurse(mcpDir);
        setAttributes(mcpDir, octal!"700");
        mcpMutex = new Mutex();
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
            if (trusted.type != JSONType.true_ && trusted.type != JSONType.false_)
                throw new Exception("Invalid managed session trust");

            sessions[id.idup] = trusted.boolean;
        }

        foreach (DirEntry entry; dirEntries(mcpDir, SpanMode.shallow))
        {
            if (entry.name.baseName.endsWith(".token"))
                std.file.remove(entry.name);
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

    string begin(Call execution)
    {
        string ret = secret();
        grants[ret] = execution;
        return ret;
    }

    Call authenticate(string token, string session, bool bind = false)
    {
        if (!token.length || !session.length)
            return null;

        Call* found = token in grants;
        if (found is null || !(*found).running || (*found).kind == CallKind.Remove)
            return null;

        Call ret = *found;
        bool started = ret.kind == CallKind.Start || ret.kind == CallKind.Print;
        if (!started && !managed(session))
            return null;
        if (!ret.sessionId.length)
        {
            if (!bind || !started || managed(session))
                return null;

            ret.identify(session);
        }
        if (ret.sessionId != session)
            return null;
        if (bind && started && !managed(session))
            remember(session, ret.trusted);

        return managed(session) ? ret : null;
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

        revokeMcp(id);
    }

    static string mint()
        => secret();

    bool admitMcp(string token, string id)
    {
        Session.validateId(id);
        if (token.length != 64)
            return false;

        synchronized (mcpMutex)
        {
            string* found = token in mcpGrants;
            if (found !is null)
                return *found == id;

            mcpGrants[token.idup] = id.idup;
            atomicWrite(mcpTokenPath(id), token);
            setAttributes(mcpTokenPath(id), octal!"600");
        }

        return true;
    }

    string mcpSession(string token)
    {
        if (!token.length)
            return null;

        synchronized (mcpMutex)
        {
            string* found = token in mcpGrants;
            return found is null ? null : *found;
        }
    }

    void revokeMcp(string id)
    {
        synchronized (mcpMutex)
        {
            foreach (token; mcpGrants.keys)
            {
                if (mcpGrants[token] == id)
                    mcpGrants.remove(token);
            }

            string path = mcpTokenPath(id);
            if (exists(path))
                std.file.remove(path);
        }
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
    string mcpDir;
    bool[string] sessions;
    Call[string] grants;
    string[string] mcpGrants;
    Mutex mcpMutex;

    string mcpTokenPath(string id) const
        => buildPath(mcpDir, id~".token");

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
