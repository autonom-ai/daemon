module autonom.coord.bus;

import autonom.agent.profile : Profile;
import autonom.agent.store : ProfileStore, validName;
import autonom.coord.room : Room;
import autonom.coord.stream : Entry, Stream;
import autonom.config : Config;
import autonom.exception : Conflict, InvalidInput;
import autonom.storage : atomicWrite, readJSON;

import std.algorithm : sort;
import std.exception : enforce;
import std.file : DirEntry, SpanMode, dirEntries, exists, isSymlink, mkdirRecurse, rmdirRecurse;
import std.json : JSONType, JSONValue;
import std.path : baseName, buildPath;
import std.string : strip, toLower;

public:

enum MESSAGES_FILE = "messages.jsonl";
enum DMS_FILE = "dms.jsonl";
enum PINGS_FILE = "pings.jsonl";
enum CURSORS_FILE = "cursors.json";

/// Validates a room name and returns its canonical lowercase form.
string canonicalRoomName(string name)
{
    name = name.strip;
    if (name.length && name[0] == '#')
        name = name[1 .. $];

    enforce!InvalidInput(validName(name), "Invalid room name");
    return name.toLower.idup;
}

/**
 * The coordination bus: global rooms, message streams, and per-profile read cursors.
 *
 * Cursors index the in-memory window of a stream and are clamped to it on load,
 * so a restart re-delivers at most one window of messages.
 */
class Bus
{
private:
    ProfileStore store;
    Room[string] rooms;
    Stream[string] streams;
    size_t[string][string] cursors;

    string roomsDir() const
        => buildPath(directory, "rooms");

    string inboxDir(string profileName) const
        => buildPath(directory, "inboxes", profileName);

    static string roomStream(string roomName)
        => "room:"~roomName;

    static string dmStream(string profileName)
        => "dms:"~profileName;

    static string pingStream(string profileName)
        => "pings:"~profileName;

    /// Gets a stream, loading it on first use.
    Stream stream(string name, string path)
    {
        if (Stream* found = name in streams)
            return *found;

        Stream ret = new Stream(name, path);
        streams[name] = ret;
        return ret;
    }

    size_t[string] loadCursors(string profileName)
    {
        string path = buildPath(inboxDir(profileName), CURSORS_FILE);
        if (!exists(path))
            return null;

        JSONValue data = readJSON(path);
        enforce(data.type == JSONType.object, "Invalid read cursors");
        size_t[string] ret;
        foreach (name, value; data.object)
        {
            enforce(value.type == JSONType.integer && value.integer >= 0, "Invalid read cursors");
            ret[name.idup] = cast(size_t)value.integer;
        }

        return ret;
    }

    void saveCursors(string profileName)
    {
        JSONValue data = JSONValue.emptyObject;
        if (size_t[string]* positions = profileName in cursors)
        {
            foreach (name, position; *positions)
                data[name] = JSONValue(cast(long)position);
        }

        mkdirRecurse(inboxDir(profileName));
        atomicWrite(buildPath(inboxDir(profileName), CURSORS_FILE), data.toString());
    }

    Entry append(Stream target, Entry entry)
    {
        size_t previous = target.entries.length;
        target.append(entry);
        size_t trimmed = previous + 1 - target.entries.length;
        if (trimmed)
            shiftCursors(target.name, trimmed);

        return entry;
    }

    void shiftCursors(string streamName, size_t trimmed)
    {
        foreach (profileName, ref positions; cursors)
        {
            size_t* position = streamName in positions;
            if (position is null)
                continue;

            *position = *position < trimmed ? 0 : *position - trimmed;
        }
    }

    /// Writes a ping entry for each distinct target other than the sender.
    void ping(Profile[] targets, Profile from, string text, string room)
    {
        bool[string] seen;
        foreach (target; targets)
        {
            if (target.name == from.name || target.name in seen)
                continue;

            seen[target.name] = true;
            append(pings(target.name), Entry.create(from.name, text, null, room));
        }
    }

    /// Reads a stream, advancing the profile's cursor past the entries returned.
    Entry[] read(Stream target, Profile profile, size_t limit)
    {
        size_t position = cursor(profile.name, target.name);
        if (!position && target.entries.length > limit)
        {
            advance(profile.name, target.name, target.entries.length);
            return target.entries[$ - limit .. $];
        }

        Entry[] ret = target.since(position);
        if (ret.length > limit)
            ret = ret[0 .. limit];

        advance(profile.name, target.name, position + ret.length);
        return ret;
    }

    /// Entries a profile has not read, excluding its own posts.
    Entry[] unread(Stream target, Profile profile)
    {
        Entry[] ret;
        foreach (entry; target.since(cursor(profile.name, target.name)))
        {
            if (entry.from != profile.name)
                ret ~= entry;
        }

        return ret;
    }

    void load()
    {
        if (exists(roomsDir))
        {
            enforce(!isSymlink(roomsDir), "Coordination directory must not be a symlink");
            foreach (DirEntry entry; dirEntries(roomsDir, SpanMode.shallow))
            {
                if (!entry.isDir || entry.isSymlink)
                    continue;

                string name = entry.name.baseName;
                if (name != name.toLower || !validName(name))
                    continue;

                Room room = Room.load(name, entry.name);
                if (room !is null)
                    rooms[name] = room;
            }
        }

        foreach (Profile profile; store.list())
            cursors[profile.name] = loadCursors(profile.name);
    }

public:
    /// Directory holding rooms and inboxes.
    const string directory;

    this(Config configuration, ProfileStore store)
    {
        this.store = store;
        directory = buildPath(configuration.dataDir, "coord");
        enforce(!(exists(directory) && isSymlink(directory)), "Coordination directory must not be a symlink");
        mkdirRecurse(directory);
        load();
    }

    /// The stream holding a room's messages.
    Stream roomMessages(Room room)
        => stream(roomStream(room.name), buildPath(room.directory, MESSAGES_FILE));

    /// The stream holding a profile's direct messages.
    Stream directMessages(string profileName)
        => stream(dmStream(profileName), buildPath(inboxDir(profileName), DMS_FILE));

    /// The stream holding a profile's pings.
    Stream pings(string profileName)
        => stream(pingStream(profileName), buildPath(inboxDir(profileName), PINGS_FILE));

    /// Gets a profile's read position for a stream.
    size_t cursor(string profileName, string streamName)
    {
        size_t[string]* positions = profileName in cursors;
        if (positions is null)
            return 0;

        size_t* position = streamName in *positions;
        return position is null ? 0 : *position;
    }

    /// Advances a profile's read position, persisting the cursor.
    void advance(string profileName, string streamName, size_t position)
    {
        if (position <= cursor(profileName, streamName))
            return;

        cursors[profileName][streamName] = position;
        saveCursors(profileName);
    }

    /// Reads a room's messages, advancing the profile's cursor.
    Entry[] readRoom(Room room, Profile profile, size_t limit)
        => read(roomMessages(room), profile, limit);

    /// Reads a profile's direct messages, advancing its cursor.
    Entry[] readDirect(Profile profile, size_t limit)
        => read(directMessages(profile.name), profile, limit);

    /// Reads a profile's pings, advancing its cursor.
    Entry[] readPings(Profile profile, size_t limit)
        => read(pings(profile.name), profile, limit);

    /// Unread pings for a profile, used by the tool gate.
    Entry[] unreadPings(Profile profile)
        => unread(pings(profile.name), profile);

    /// Posts to a room and pings the targets.
    Entry post(Room room, Profile from, string text, Profile[] targets)
    {
        Entry ret = append(roomMessages(room), Entry.create(from.name, text, null, room.name));
        ping(targets, from, text, room.name);
        return ret;
    }

    /// Sends a direct message and pings the targets.
    Entry direct(Profile to, Profile from, string text, Profile[] targets)
    {
        Entry ret = append(directMessages(to.name), Entry.create(from.name, text, to.name));
        ping(targets, from, text, null);
        return ret;
    }

    /// Describes a room for the room list: message count, unread count, and last activity.
    JSONValue roomEntry(Room room, Profile profile)
    {
        Stream target = roomMessages(room);
        Entry[] entries = target.entries;
        JSONValue ret = JSONValue.emptyObject;
        ret["name"] = JSONValue(room.name);
        ret["count"] = JSONValue(cast(long)entries.length);
        ret["unread"] = JSONValue(cast(long)unread(target, profile).length);
        ret["lastTs"] = entries.length ? JSONValue(entries[$ - 1].timestamp) : JSONValue(null);
        return ret;
    }

    /// Lists the rooms a profile may see, ordered by name.
    Room[] visibleRooms(string profileName)
    {
        Room[] ret;
        foreach (name, room; rooms)
        {
            if (room.visible(profileName))
                ret ~= room;
        }

        ret.sort!((left, right) => left.name < right.name);
        return ret;
    }

    /// Gets a room by name, or null when it does not exist.
    Room getRoom(string name)
    {
        Room* found = canonicalRoomName(name) in rooms;
        return found is null ? null : *found;
    }

    /// Creates a room owned by a profile.
    Room createRoom(string name, string ownerProfileName)
    {
        name = canonicalRoomName(name);
        enforce!Conflict(name !in rooms, "Room already exists");
        string path = buildPath(roomsDir, name);
        enforce(!exists(path), "Room directory already exists");
        mkdirRecurse(roomsDir);
        Room ret = Room.create(name, path, ownerProfileName);
        rooms[name] = ret;
        return ret;
    }

    /// Deletes a room and its messages.
    void deleteRoom(Room room)
    {
        rmdirRecurse(room.directory);
        rooms.remove(room.name);
        streams.remove(roomStream(room.name));
    }
}
