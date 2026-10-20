module daemon.agent.store;

import daemon.agent.profile;
import daemon.config;
import daemon.exception;
import daemon.interop.provider : IProvider;
import daemon.interop.session : Session;
import daemon.storage;

import std.algorithm : sort;
import std.ascii;
import std.conv : octal;
import std.exception : basicExceptionCtors;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : baseName, buildPath;
import std.string : toLower;

private string canonicalName(string name)
{
    if (!validName(name))
        throw new InvalidInputException("Invalid profile name");

    return name.toLower.idup;
}

bool validName(string name)
{
    if (!name.length || name.length > 64 || !isAlphaNum(name[0]))
        return false;

    foreach (character; name)
    {
        if (!isAlphaNum(character) && character != '-' && character != '_')
            return false;
    }

    return true;
}

class ProfileConflictException : ConflictException
{
    mixin basicExceptionCtors;
}

class ProfileStore
{
private:
    static ProfileStore instance;
    IProvider bridge;
    Profile human;
    Profile[string] profiles;
    string[string] assignments;
    string[string] bindings;

public:
    const string directory;

    static ProfileStore get() => instance;

    static void set(ProfileStore store)
    {
        instance = store;
    }

    this(Config configuration, IProvider bridge)
    {
        this.bridge = bridge;
        human = new Profile(humanName);
        directory = buildPath(configuration.dataDir, "agents");
        if ((exists(configuration.dataDir) && isSymlink(configuration.dataDir)) ||
            (exists(directory) && isSymlink(directory)))
            throw new Exception("Profile directory must not be a symlink");
        mkdirRecurse(directory);
        load();
    }

    Profile[] list()
    {
        string[] names = profiles.keys;
        names.sort();
        Profile[] ret = new Profile[names.length];
        foreach (i, name; names)
            ret[i] = profiles[name];

        return ret;
    }

    Profile get(string name)
    {
        name = canonicalName(name);
        if (name == humanName)
            return human;

        Profile* found = name in profiles;
        return found is null ? null : *found;
    }

    bool assigned(string id) const
        => (id in assignments) !is null;

    Profile profileFor(string id)
    {
        string* owner = id in assignments;
        if (owner is null)
            return null;

        Profile profile = get(*owner);
        if (profile is null)
            throw new Exception("The linked profile no longer exists");

        return profile.session is null || profile.session.id == id ? profile : null;
    }

    Profile create(string name)
    {
        name = canonicalName(name);
        if (name == humanName)
            throw new ProfileConflictException("The human profile is reserved");

        if (name in profiles)
            throw new ProfileConflictException("Profile already exists");

        string path = buildPath(directory, name);
        if (exists(path))
            throw new Exception("Profile directory already exists");

        mkdir(path);
        bool committed;
        scope(failure)
        {
            if (!committed)
                rmdir(path);
        }

        setAttributes(path, octal!"700");
        Profile ret = new Profile(name);
        string[string] nextBindings = bindings.dup;
        nextBindings[name] = null;
        scope(exit)
        {
            if (committed)
            {
                bindings = nextBindings;
                profiles[name] = ret;
            }
        }

        save(assignments, nextBindings, committed);
        return ret;
    }

    Profile register(string name, string id)
    {
        name = canonicalName(name);
        if (name == humanName)
            throw new ProfileConflictException("The human profile is reserved");

        Session.validateId(id);
        if (bridge.isRemoved(id))
            throw new ProfileConflictException("Session was removed");

        if (string* owner = id in assignments)
        {
            if (*owner != name)
                throw new ProfileConflictException("Session is already linked to another profile");
        }

        Profile ret = get(name);
        if (ret !is null && ret.session !is null && ret.session.id != id && locked(ret))
            throw new ProfileConflictException("Profile is in use by an active session");

        bool created = ret is null;
        string path = buildPath(directory, name);
        bool committed;
        if (created)
        {
            if (exists(path))
                throw new Exception("Profile directory already exists");

            mkdir(path);
        }

        scope(failure)
        {
            if (created && !committed)
                rmdir(path);
        }

        if (created)
        {
            setAttributes(path, octal!"700");
            ret = new Profile(name);
        }

        Session session = bridge.session(id);
        string[string] nextAssignments = assignments.dup;
        string[string] nextBindings = bindings.dup;
        nextAssignments[session.id] = name;
        nextBindings[name] = session.id;
        scope(exit)
        {
            if (committed)
            {
                assignments = nextAssignments;
                bindings = nextBindings;
                profiles[name] = ret;
                ret.bind(session);
            }
        }

        save(nextAssignments, nextBindings, committed);
        return ret;
    }

    void unlinkSession(string id)
    {
        Session.validateId(id);
        if (id !in assignments)
            return;

        Profile profile = profileFor(id);
        string[string] nextAssignments = assignments.dup;
        string[string] nextBindings = bindings.dup;
        nextAssignments.remove(id);
        if (profile !is null)
            nextBindings[profile.name] = null;

        bool committed;
        scope(exit)
        {
            if (committed)
            {
                assignments = nextAssignments;
                bindings = nextBindings;
                if (profile !is null)
                    profile.bind(null);
            }
        }

        save(nextAssignments, nextBindings, committed);
    }

private:
    string statePath() const
        => buildPath(directory, "state.json");

    bool locked(Profile profile)
        => profile.session !is null && (profile.session.hasActiveCall() || bridge.online(profile.session.id));

    void load()
    {
        if (exists(statePath))
        {
            JSONValue data = readJSON(statePath);
            if (data.type != JSONType.object || data.object.length != 3 || "version" !in data.object ||
                data["version"] != JSONValue(1) || "assignments" !in data.object || "bindings" !in data.object)
                throw new Exception("Invalid profile state");

            if (data["assignments"].type != JSONType.object || data["bindings"].type != JSONType.object)
                throw new Exception("Invalid profile state");

            foreach (id, name; data["assignments"].object)
            {
                Session.validateId(id);
                if (name.type != JSONType.string)
                    throw new Exception("Invalid session mapping");

                assignments[id.idup] = canonicalName(name.str);
            }

            foreach (name, value; data["bindings"].object)
            {
                if (name != canonicalName(name) || (value.type != JSONType.string && !value.isNull))
                    throw new Exception("Invalid profile binding");

                string path = buildPath(directory, name);
                if (!isDir(path) || isSymlink(path))
                    throw new Exception("Profile directory is unavailable");

                bindings[name.idup] = value.isNull ? null : value.str.idup;
            }
        }
        else
        {
            string path = buildPath(directory, "sessions.json");
            if (exists(path))
            {
                JSONValue data = readJSON(path);
                if (data.type != JSONType.object)
                    throw new Exception("Invalid session mapping");

                foreach (id, name; data.object)
                {
                    Session.validateId(id);
                    if (name.type != JSONType.string)
                        throw new Exception("Invalid session mapping");

                    assignments[id.idup] = canonicalName(name.str);
                }
            }

            foreach (DirEntry entry; dirEntries(directory, SpanMode.shallow))
            {
                if (!entry.isDir || entry.isSymlink)
                    continue;

                string name = entry.name.baseName;
                if (name != canonicalName(name))
                    throw new Exception("Invalid stored profile name");

                bindings[name.idup] = null;
                path = buildPath(directory, name, "session.json");
                if (exists(path))
                {
                    JSONValue data = readJSON(path);
                    if (data.type != JSONType.object || "session_id" !in data.object ||
                        data["session_id"].type != JSONType.string)
                        throw new Exception("Invalid profile session");

                    bindings[name] = data["session_id"].str.idup;
                }
            }
        }

        foreach (id, name; assignments)
        {
            if (name !in bindings)
                throw new Exception("The linked profile no longer exists");
        }

        foreach (name, id; bindings)
        {
            if (id.length)
            {
                Session.validateId(id);
                if (id !in assignments || assignments[id] != name)
                    throw new Exception("Invalid session mapping");
            }

            profiles[name] = new Profile(name, id.length ? bridge.session(id) : null);
        }

        if (!exists(statePath) && bindings.length)
        {
            bool committed;
            save(assignments, bindings, committed);
        }
    }

    void save(string[string] nextAssignments, string[string] nextBindings, out bool committed)
    {
        JSONValue data = JSONValue.emptyObject;
        data["version"] = JSONValue(1);
        data["assignments"] = JSONValue(nextAssignments);
        data["bindings"] = JSONValue.emptyObject;
        foreach (name, id; nextBindings)
            data["bindings"][name] = id.length ? JSONValue(id) : JSONValue(null);

        atomicWrite(statePath, data.toString(), committed);
    }
}
