module autonom.profilestore;

import autonom.config : Config;
import autonom.daemon.server : profileStore, readField, respond;
import autonom.profile : Profile;
import autonom.session.bridge : Bridge;
import autonom.session.session : Session;
import autonom.storage : atomicWrite, openFile;
import serverino : Output, Request, endpoint, route;

import core.sys.posix.fcntl : O_CREAT, O_RDONLY, O_RDWR;
import core.sys.linux.sys.file : flock, LOCK_EX;
import std.algorithm : sort, startsWith;
import std.array : join;
import std.ascii : isAlphaNum;
import std.exception : enforce, errnoEnforce;
import std.file : exists, isSymlink, mkdirRecurse, FileException;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.stdio : File;
import std.string : split, toLower;

private:

bool profileRoute(bool SESSION)(const Request request)
{
    enum PREFIX = "/api/profiles/";
    if (!request.path.startsWith(PREFIX))
        return false;

    string[] segments = request.path[PREFIX.length..$].split('/');
    static if (SESSION)
        return segments.length == 2 && segments[1] == "session";
    else
        return segments.length == 1;
}

string profileName(Request request)
    => request.path["/api/profiles/".length..$].split('/')[0];

public:

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

@endpoint @route!(profileRoute!false)
void getProfile(Request request, Output output)
{
    Profile profile = profileStore.get(request.profileName);
    if (profile is null)
        respond(output, JSONValue(["error": JSONValue("Profile not found")]), 404);
    else if (request.method == Request.Method.Get)
        respond(output, profile.toJSON());
    else
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
}

@endpoint @route!(profileRoute!true)
void profileSession(Request request, Output output)
{
    Profile profile = profileStore.get(request.profileName);
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

class ProfileConflict : Exception
{
public:
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

class ProfileStore
{
private:
    Config configuration;
    Bridge bridge;
    Session[string] sessions;

    File lock()
    {
        File ret = openFile(buildPath(directory, "profiles.lock"), O_RDWR | O_CREAT);
        scope(failure)
            ret.close();

        errnoEnforce(flock(ret.fileno, LOCK_EX) == 0, "Could not lock profiles");
        return ret;
    }

    JSONValue read()
    {
        string path = buildPath(directory, "profiles.json");
        if (!exists(path))
            return JSONValue.emptyObject;

        File file = openFile(path, O_RDONLY);
        scope(exit)
            file.close();

        try
        {
            JSONValue ret = parseJSON(cast(string)file.byChunk(4096).join);
            enforce(ret.type == JSONType.object, "Invalid profile registry");
            bool[string] assigned;
            foreach (name, value; ret.object)
            {
                enforce(name == canonicalName(name), "Invalid stored profile name");
                enforce(value.type == JSONType.null_ || value.type == JSONType.string, "Invalid stored session");
                if (value.type == JSONType.string)
                {
                    sessionFor(value.str);
                    enforce(value.str !in assigned, "Session belongs to multiple profiles");
                    assigned[value.str] = true;
                }
            }
            return ret;
        }
        catch (Exception error)
            throw new FileException(path, error.msg);
    }

    Session sessionFor(string id)
    {
        if (id !in sessions)
            sessions[id] = bridge.session(id);

        return sessions[id];
    }

    Profile profile(string name, JSONValue value)
    {
        return new Profile(name, value.type == JSONType.null_ ? null : sessionFor(value.str));
    }

    static string canonicalName(string name)
    {
        enforce(name.length && name.length <= 64 && isAlphaNum(name[0]), "Invalid profile name");
        foreach (character; name)
            enforce(isAlphaNum(character) || character == '-' || character == '_', "Invalid profile name");

        return name.toLower;
    }

public:
    const string directory;

    this(Config configuration, Bridge bridge)
    {
        this.configuration = configuration;
        this.bridge = bridge;
        directory = buildPath(configuration.dataDir, "agents");
        enforce(!(exists(configuration.dataDir) && isSymlink(configuration.dataDir)) &&
            !(exists(directory) && isSymlink(directory)), "Profile directory must not be a symlink");
        mkdirRecurse(directory);
    }

    Profile[] list()
    {
        File guard = lock();
        scope(exit)
            guard.close();

        JSONValue registry = read();
        string[] names = registry.object.keys;
        names.sort();
        Profile[] ret = new Profile[names.length];
        foreach (i, name; names)
            ret[i] = profile(name, registry[name]);

        return ret;
    }

    Profile get(string name)
    {
        name = canonicalName(name);
        File guard = lock();
        scope(exit)
            guard.close();

        JSONValue registry = read();
        return name in registry.object ? profile(name, registry[name]) : null;
    }

    Profile create(string name)
    {
        name = canonicalName(name);
        File guard = lock();
        scope(exit)
            guard.close();

        JSONValue registry = read();
        enforce!ProfileConflict(name !in registry.object, "Profile already exists");
        registry[name] = JSONValue(null);
        atomicWrite(buildPath(directory, "profiles.json"), registry.toString());
        return new Profile(name);
    }

    Profile register(string name, string id)
    {
        name = canonicalName(name);
        File guard = lock();
        scope(exit)
            guard.close();

        JSONValue registry = read();
        foreach (owner, value; registry.object)
            enforce!ProfileConflict(owner == name || value.type == JSONType.null_ || value.str != id,
                "Session belongs to another profile");

        Session previous;
        if (name in registry.object && registry[name].type == JSONType.string && registry[name].str != id)
        {
            previous = sessionFor(registry[name].str);
            enforce!ProfileConflict(!previous.isRunning() && !previous.isOnline(),
                "Profile already has an active session");
        }

        registry[name] = JSONValue(id);
        atomicWrite(buildPath(directory, "profiles.json"), registry.toString());
        if (previous !is null)
            sessions.remove(previous.id);

        return new Profile(name, sessionFor(id));
    }
}
