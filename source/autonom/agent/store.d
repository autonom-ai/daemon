module autonom.agent.store;

import autonom.agent.profile : Profile;
import autonom.config : Config;
import autonom.interop.bridge : Bridge;
import autonom.interop.session : Session;
import autonom.server : profileStore, readField, respond;
import autonom.storage : atomicWrite, openFile;
import serverino : Output, Request, endpoint, route;

import core.sys.posix.fcntl : O_RDONLY;
import std.algorithm : sort, startsWith;
import std.array : join, split;
import std.ascii : isAlphaNum;
import std.conv : octal;
import std.exception : enforce;
import std.file : DirEntry, FileException, SpanMode, dirEntries, exists, isSymlink, mkdir, mkdirRecurse, remove,
    setAttributes;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath;
import std.stdio : File;
import std.string : toLower;

@endpoint @route!"/api/profiles"
void profiles(Request request, Output output)
{
    if (request.method == Request.Method.Get)
    {
        JSONValue[] ret;
        foreach (profile; profileStore.list())
            ret ~= profile.toJSON();

        respond(output, JSONValue(ret));
    }
    else if (request.method == Request.Method.Post)
        respond(output, profileStore.create(readField!"name"(request)).toJSON(), 201);
    else
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
}

@endpoint @route!(sessionRoute)
void profileSession(Request request, Output output)
{
    Profile profile = profileStore.get(request.path["/api/profiles/".length..$].split('/')[0]);
    if (profile is null)
        respond(output, JSONValue(["error": JSONValue("Profile not found")]), 404);
    else if (request.method == Request.Method.Post)
        respond(output, profileStore.register(profile.name, readField!"id"(request)).toJSON());
    else if (request.method != Request.Method.Get)
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
    else if (profile.session !is null)
        respond(output, profile.session.toJSON());
    else
        respond(output, JSONValue(["error": JSONValue("Profile has no session")]), 404);
}

private:

bool sessionRoute(const Request request)
{
    enum PREFIX = "/api/profiles/";
    if (!request.path.startsWith(PREFIX))
        return false;

    string[] segments = request.path[PREFIX.length..$].split('/');
    return segments.length == 2 && segments[1] == "session";
}

string canonicalName(string name)
{
    enforce(name.length && name.length <= 64 && isAlphaNum(name[0]), "Invalid profile name");
    foreach (character; name)
        enforce(isAlphaNum(character) || character == '-' || character == '_', "Invalid profile name");

    return name.toLower;
}

public:

class ProfileConflict : Exception
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
 * The shared `sessions.json` records permanent session-to-profile links, while
 * each profile directory holds its own `session.json` binding. A profile is
 * locked while its bound session is running or online, which prevents rebinding
 * until the session stops.
 */
class ProfileStore
{
private:
    Bridge bridge;
    Profile[string] profiles;
    string[string] assignments;
    Session[string] sessions;

    string assignmentPath() const
        => buildPath(directory, "sessions.json");

    string bindingPath(string name) const
        => buildPath(directory, name, "session.json");

    static JSONValue readJSON(string path)
    {
        File file = openFile(path, O_RDONLY);
        scope(exit)
            file.close();

        try
            return parseJSON(cast(string)file.byChunk(4096).join);
        catch (Exception error)
            throw new FileException(path, error.msg);
    }

    bool locked(Profile profile)
        => profile.session !is null && (profile.session.isRunning() || bridge.online(profile.session.id));

    void load()
    {
        string path = assignmentPath();
        if (exists(path))
        {
            JSONValue data = readJSON(path);
            enforce(data.type == JSONType.object, "Invalid session mapping");
            foreach (session, name; data.object)
            {
                enforce(session.length && name.type == JSONType.string, "Invalid session mapping");
                assignments[session.idup] = canonicalName(name.str);
            }
        }

        foreach (DirEntry entry; dirEntries(directory, SpanMode.shallow))
        {
            if (!entry.isDir || entry.isSymlink)
                continue;

            string name = entry.name.baseName;
            enforce(name == canonicalName(name), "Invalid stored profile name");
            Profile profile = new Profile(name);
            profiles[name] = profile;
            path = bindingPath(name);
            if (exists(path))
            {
                JSONValue data = readJSON(path);
                enforce(data.type == JSONType.object && "session_id" in data.object &&
                    data["session_id"].type == JSONType.string, "Invalid profile session");
                profile.session = sessionFor(data["session_id"].str);
            }
        }

        foreach (name, profile; profiles)
        {
            if (profile.session is null)
                continue;

            string* owner = profile.session.id in assignments;
            enforce(owner !is null && *owner == name, "Invalid session mapping");
        }
    }

    void saveAssignments()
    {
        JSONValue data = JSONValue.emptyObject;
        foreach (session, name; assignments)
            data[session] = JSONValue(name);

        atomicWrite(assignmentPath(), data.toString());
    }

    void saveBinding(Profile profile)
    {
        string path = bindingPath(profile.name);
        if (profile.session is null)
        {
            if (exists(path))
                remove(path);

            return;
        }

        atomicWrite(path, JSONValue(["session_id": JSONValue(profile.session.id)]).toString());
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
        if (profile.session is null || profile.session.id == id)
            return profile;

        return null;
    }

    /// Creates a profile, failing when the name is taken.
    Profile create(string name)
    {
        name = canonicalName(name);
        enforce!ProfileConflict(name !in profiles, "Profile already exists");
        string path = buildPath(directory, name);
        enforce(!(exists(path) && isSymlink(path)), "Profile directory must not be a symlink");
        mkdir(path);
        setAttributes(path, octal!"700");
        Profile ret = new Profile(name);
        profiles[name] = ret;
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
        Session session = sessionFor(id);
        if (string* owner = session.id in assignments)
            enforce!ProfileConflict(*owner == name, "Session is already linked to another profile");

        Profile profile = get(name);
        if (profile is null)
            profile = create(name);

        if (profile.session !is null && profile.session.id != session.id)
        {
            enforce!ProfileConflict(!locked(profile), "Profile is in use by an active session");
            sessions.remove(profile.session.id);
        }

        profile.session = session;
        assignments[session.id] = name;
        saveAssignments();
        saveBinding(profile);
        return profile;
    }

    /// Gets the live session handle for an ID, creating it on first use.
    Session sessionFor(string id)
    {
        if (Session* cached = id in sessions)
            return *cached;

        Session ret = bridge.session(id);
        sessions[ret.id] = ret;
        return ret;
    }

    /// Removes the session and clears any profile binding to it.
    void removeSession(string id)
    {
        sessionFor(id).remove();
        Profile profile = profileFor(id);
        if (profile !is null)
        {
            profile.session = null;
            saveBinding(profile);
        }

        assignments.remove(id);
        saveAssignments();
        sessions.remove(id);
    }

    /// Stops every session process owned by this store.
    void stopSessions()
    {
        foreach (session; sessions)
        {
            if (session.isRunning())
                session.stop();
        }
    }
}
