module autonom.agent.store;

import autonom.agent.profile : HUMAN_NAME, Profile;
import autonom.config : Config;
import autonom.exception : Conflict, InvalidInput;
import autonom.interop.bridge : Bridge;
import autonom.interop.session : Session;
import autonom.server : acceptMethod, matchesPath, profileStore, readField, respond, routeParameter;
import autonom.storage : atomicWrite, readJSON;
import serverino : Output, Request, endpoint, route;

import std.algorithm : sort;
import std.ascii : isAlphaNum;
import std.conv : octal;
import std.exception : enforce;
import std.file : DirEntry, SpanMode, dirEntries, exists, isDir, isSymlink, mkdir, mkdirRecurse, rmdir,
    setAttributes;
import std.json : JSONType, JSONValue;
import std.path : baseName, buildPath;
import std.string : toLower;

public:

@endpoint @route!"/api/profiles"
void profiles(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    if (request.method == Request.Method.Get)
    {
        JSONValue[] ret;
        foreach (profile; profileStore.list())
            ret ~= profile.toJSON();

        respond(output, JSONValue(ret));
    }
    else
        respond(output, profileStore.create(readField!"name"(request)).toJSON(), 201);
}

@endpoint @route!(matchesPath!"/api/profiles/<name>/session")
void profileSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get, Request.Method.Post]))
        return;

    Profile profile = profileStore.get(routeParameter!"/api/profiles/<name>/session"(request));
    if (profile is null)
        respond(output, JSONValue(["error": JSONValue("Profile not found")]), 404);
    else if (request.method == Request.Method.Post)
        respond(output, profileStore.register(profile.name, readField!"id"(request)).toJSON());
    else if (profile.session !is null)
        respond(output, profile.session.toJSON());
    else
        respond(output, JSONValue(["error": JSONValue("Profile has no session")]), 404);
}

private:

string canonicalName(string name)
{
    enforce!InvalidInput(validName(name), "Invalid profile name");
    return name.toLower.idup;
}

public:

/// Reports whether a name is valid for a profile or room.
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

class ProfileConflict : Conflict
{
public:
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/**
 * In-memory profile state with durable session mappings.
 *
 * Permanent assignments and current bindings commit together in state.json.
 * Legacy sessions.json and per-profile session.json files are imported only
 * when no authoritative snapshot exists and are retained without modification.
 */
class ProfileStore
{
private:
    Bridge bridge;
    Profile[string] profiles;
    string[string] assignments;
    string[string] bindings;

    string statePath() const
        => buildPath(directory, "state.json");

    bool locked(Profile profile)
        => profile.session !is null && (profile.session.isRunning() || bridge.online(profile.session.id));

    void load()
    {
        if (exists(statePath))
        {
            JSONValue data = readJSON(statePath);
            enforce(data.type == JSONType.object && data.object.length == 3 && "version" in data.object &&
                data["version"] == JSONValue(1) && "assignments" in data.object && "bindings" in data.object,
                "Invalid profile state");
            enforce(data["assignments"].type == JSONType.object && data["bindings"].type == JSONType.object,
                "Invalid profile state");
            foreach (id, name; data["assignments"].object)
            {
                Session.validateId(id);
                enforce(name.type == JSONType.string, "Invalid session mapping");
                assignments[id.idup] = canonicalName(name.str);
            }

            foreach (name, value; data["bindings"].object)
            {
                enforce(name == canonicalName(name) && (value.type == JSONType.string || value.isNull),
                    "Invalid profile binding");
                string path = buildPath(directory, name);
                enforce(isDir(path) && !isSymlink(path), "Profile directory is unavailable");
                bindings[name.idup] = value.isNull ? null : value.str.idup;
            }
        }
        else
        {
            string path = buildPath(directory, "sessions.json");
            if (exists(path))
            {
                JSONValue data = readJSON(path);
                enforce(data.type == JSONType.object, "Invalid session mapping");
                foreach (id, name; data.object)
                {
                    Session.validateId(id);
                    enforce(name.type == JSONType.string, "Invalid session mapping");
                    assignments[id.idup] = canonicalName(name.str);
                }
            }

            foreach (DirEntry entry; dirEntries(directory, SpanMode.shallow))
            {
                if (!entry.isDir || entry.isSymlink)
                    continue;

                string name = entry.name.baseName;
                enforce(name == canonicalName(name), "Invalid stored profile name");
                bindings[name.idup] = null;
                path = buildPath(directory, name, "session.json");
                if (exists(path))
                {
                    JSONValue data = readJSON(path);
                    enforce(data.type == JSONType.object && "session_id" in data.object &&
                        data["session_id"].type == JSONType.string, "Invalid profile session");
                    bindings[name] = data["session_id"].str.idup;
                }
            }
        }

        foreach (id, name; assignments)
            enforce(name in bindings, "The linked profile no longer exists");

        foreach (name, id; bindings)
        {
            if (id.length)
            {
                Session.validateId(id);
                enforce(id in assignments && assignments[id] == name, "Invalid session mapping");
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

public:
    const string directory;

    this(Config configuration, Bridge bridge)
    {
        this.bridge = bridge;
        directory = buildPath(configuration.dataDir, "agents");
        enforce(!(exists(configuration.dataDir) && isSymlink(configuration.dataDir)) &&
            !(exists(directory) && isSymlink(directory)), "Profile directory must not be a symlink");
        mkdirRecurse(directory);
        load();
    }

    /// Lists profiles ordered by name.
    Profile[] list()
    {
        string[] names = profiles.keys;
        names.sort();
        Profile[] ret = new Profile[names.length];
        foreach (i, name; names)
            ret[i] = profiles[name];

        return ret;
    }

    /// Gets a profile by name, or null when unknown.
    Profile get(string name)
    {
        Profile* found = canonicalName(name) in profiles;
        return found is null ? null : *found;
    }

    /// Gets the profile currently linked to a session, or null when unlinked.
    Profile profileFor(string id)
    {
        string* owner = id in assignments;
        if (owner is null)
            return null;

        Profile profile = get(*owner);
        enforce(profile !is null, "The linked profile no longer exists");
        return profile.session is null || profile.session.id == id ? profile : null;
    }

    /// Creates a profile, failing when the name is taken.
    Profile create(string name)
    {
        name = canonicalName(name);
        enforce!ProfileConflict(name != HUMAN_NAME, "The human profile is reserved");
        enforce!ProfileConflict(name !in profiles, "Profile already exists");
        string path = buildPath(directory, name);
        enforce(!exists(path), "Profile directory already exists");
        mkdir(path);
        bool committed;
        scope(failure)
            if (!committed)
                rmdir(path);

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

    /**
     * Links a session to a profile.
     *
     * Sessions keep their profile permanently, while a profile can move to a
     * new session only while its current session is stopped and offline.
     */
    Profile register(string name, string id)
    {
        name = canonicalName(name);
        enforce!ProfileConflict(name != HUMAN_NAME, "The human profile is reserved");
        Session.validateId(id);
        enforce!ProfileConflict(!bridge.isRemoved(id), "Session was removed");
        if (string* owner = id in assignments)
            enforce!ProfileConflict(*owner == name, "Session is already linked to another profile");

        Profile ret = get(name);
        if (ret !is null && ret.session !is null && ret.session.id != id)
            enforce!ProfileConflict(!locked(ret), "Profile is in use by an active session");

        bool created = ret is null;
        string path = buildPath(directory, name);
        bool committed;
        if (created)
        {
            enforce(!exists(path), "Profile directory already exists");
            mkdir(path);
        }

        scope(failure)
            if (created && !committed)
                rmdir(path);

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

    /// Clears profile state after its backend session has been removed.
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
}
