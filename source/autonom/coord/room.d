module autonom.coord.room;

import autonom.agent.profile : HUMAN_NAME;
import autonom.storage : atomicWrite, readJSON;

import std.conv : octal;
import std.exception : enforce;
import std.file : exists, mkdir, setAttributes;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.uni : sicmp;

// TODO: Room policy based on profile last message and locked room support for PRs/conflicts to
// mandate a resolution between involved parties.

private:

enum MEMBERSHIP_FILE = "profiles.json";

public:

/// A room: a message stream and the profiles that may use it.
class Room
{
private:
    string[] admins;
    string[] involved;
    bool restricted;

    static string[] listed(JSONValue value)
    {
        enforce(value.type == JSONType.array, "Invalid room membership");
        string[] ret = new string[0];
        foreach (entry; value.array)
        {
            enforce(entry.type == JSONType.string && entry.str.length, "Invalid room membership");
            ret ~= entry.str;
        }

        return ret;
    }

    static bool named(string[] names, string profileName)
    {
        foreach (name; names)
        {
            if (sicmp(name, profileName) == 0)
                return true;
        }

        return false;
    }

    /// Serializes the involved list, representing an unrestricted room as JSON null.
    JSONValue involvedJSON()
    {
        if (!restricted)
            return JSONValue(null);

        JSONValue ret = JSONValue.emptyArray;
        foreach (name; involved)
            ret.array ~= JSONValue(name);

        return ret;
    }

    string membershipPath() const
        => buildPath(directory, MEMBERSHIP_FILE);

    void save()
    {
        JSONValue data = JSONValue.emptyObject;
        data["owner"] = JSONValue(owner);
        data["admins"] = JSONValue(admins);
        data["involved"] = involvedJSON();
        atomicWrite(membershipPath, data.toString());
    }

public:
    /// Canonical room name.
    const string name;
    /// Directory holding the room's stream and membership.
    const string directory;
    /// Profile that created the room.
    string owner;

    this(string name, string directory, string owner)
    {
        this.name = name.idup;
        this.directory = directory.idup;
        this.owner = owner.idup;
        admins = new string[0];
    }

    /// Creates a room directory and its membership file.
    static Room create(string name, string directory, string owner)
    {
        enforce(!exists(directory), "Room directory already exists");
        mkdir(directory);
        setAttributes(directory, octal!"700");
        Room ret = new Room(name, directory, owner);
        ret.save();
        return ret;
    }

    /// Loads a room, or returns null when its membership file is absent.
    static Room load(string name, string directory)
    {
        string path = buildPath(directory, MEMBERSHIP_FILE);
        if (!exists(path))
            return null;

        JSONValue data = readJSON(path);
        enforce(data.type == JSONType.object && "owner" in data.object && data["owner"].type == JSONType.string &&
            "admins" in data.object && "involved" in data.object, "Invalid room membership");
        Room ret = new Room(name, directory, data["owner"].str);
        ret.admins = listed(data["admins"]);
        ret.restricted = !data["involved"].isNull;
        if (ret.restricted)
            ret.involved = listed(data["involved"]);

        return ret;
    }

    /// Reports whether the profile created the room; the human profile owns every room.
    bool originalOwner(string profileName)
        => sicmp(owner, profileName) == 0 || sicmp(HUMAN_NAME, profileName) == 0;

    /// Reports whether the profile was granted administration.
    bool admin(string profileName)
        => named(admins, profileName);

    /// Reports whether the profile administers the room.
    bool administrator(string profileName)
        => originalOwner(profileName) || admin(profileName);

    /// Reports whether the profile may use the room; an unrestricted room admits every profile.
    bool member(string profileName)
        => !restricted || named(involved, profileName);

    /// Reports whether the profile knows that the room exists.
    bool visible(string profileName)
        => administrator(profileName) || member(profileName);

    /// Grants administration to a profile.
    void addAdmin(string profileName)
    {
        if (!admin(profileName))
            admins ~= profileName.idup;

        save();
    }

    /// Removes administration from a profile.
    void removeAdmin(string profileName)
    {
        string[] ret = new string[0];
        foreach (name; admins)
        {
            if (sicmp(name, profileName) != 0)
                ret ~= name;
        }

        admins = ret;
        save();
    }

    /// Admits every profile to the room.
    void involveEveryone()
    {
        restricted = false;
        involved = null;
        save();
    }

    /// Restricts the room to the supplied profiles; an empty list admits administrators only.
    void setInvolved(string[] profileNames)
    {
        restricted = true;
        involved = profileNames.dup;
        save();
    }

    /// Serializes the room's membership.
    JSONValue toJSON()
    {
        JSONValue ret = JSONValue.emptyObject;
        ret["name"] = JSONValue(name);
        ret["owner"] = JSONValue(owner);
        ret["admins"] = JSONValue(admins);
        ret["involved"] = involvedJSON();
        return ret;
    }
}
