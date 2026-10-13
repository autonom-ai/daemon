module daemon.coord.room;

import daemon.agent;
import daemon.storage;

import std.conv : octal;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.uni : sicmp;


private:

enum MEMBERSHIP_FILE = "profiles.json";

public:

class Room
{
private:
    string[] admins;
    string[] involved;
    bool restricted;

    static string[] listed(JSONValue value)
    {
        if (value.type != JSONType.array)
            throw new Exception("Invalid room membership");

        string[] ret = new string[0];
        foreach (entry; value.array)
        {
            if (entry.type != JSONType.string || !entry.str.length)
                throw new Exception("Invalid room membership");

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
    const string name;
    const string directory;
    string owner;

    this(string name, string directory, string owner)
    {
        this.name = name.idup;
        this.directory = directory.idup;
        this.owner = owner.idup;
        admins = new string[0];
    }

    static Room create(string name, string directory, string owner)
    {
        if (exists(directory))
            throw new Exception("Room directory already exists");

        mkdir(directory);
        setAttributes(directory, octal!"700");
        Room ret = new Room(name, directory, owner);
        ret.save();
        return ret;
    }

    static Room load(string name, string directory)
    {
        string path = buildPath(directory, MEMBERSHIP_FILE);
        if (!exists(path))
            return null;

        JSONValue data = readJSON(path);
        if (data.type != JSONType.object || "owner" !in data.object || data["owner"].type != JSONType.string ||
            "admins" !in data.object || "involved" !in data.object)
            throw new Exception("Invalid room membership");

        Room ret = new Room(name, directory, data["owner"].str);
        ret.admins = listed(data["admins"]);
        ret.restricted = !data["involved"].isNull;
        if (ret.restricted)
            ret.involved = listed(data["involved"]);

        return ret;
    }

    bool originalOwner(string profileName)
        => sicmp(owner, profileName) == 0 || sicmp(HUMAN_NAME, profileName) == 0;

    bool admin(string profileName)
        => named(admins, profileName);

    bool administrator(string profileName)
        => originalOwner(profileName) || admin(profileName);

    bool member(string profileName)
        => !restricted || named(involved, profileName);

    bool visible(string profileName)
        => administrator(profileName) || member(profileName);

    void addAdmin(string profileName)
    {
        if (!admin(profileName))
            admins ~= profileName.idup;

        save();
    }

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

    void involveEveryone()
    {
        restricted = false;
        involved = null;
        save();
    }

    void setInvolved(string[] profileNames)
    {
        restricted = true;
        involved = profileNames.dup;
        save();
    }

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
