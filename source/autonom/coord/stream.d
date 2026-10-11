module autonom.coord.stream;

import autonom.storage : openFile;

import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDONLY, O_RDWR;
import std.array : join;
import std.datetime : Clock, UTC;
import std.file : exists, mkdirRecurse;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : dirName;
import std.stdio : File;
import std.string : indexOf, splitLines;
import std.uuid : randomUUID;

public:

/// Entries a stream keeps in memory.
enum MAX_ENTRIES = 1000;
/// Bytes a stream reads when it loads its log.
enum MAX_LOG_BYTES = 4 * 1024 * 1024;
/// Hectonanoseconds in a millisecond.
enum HNSSECS_PER_MSEC = 10_000;

/// One message on the bus.
struct Entry
{
private:
    static bool parse(JSONValue data, out Entry entry)
    {
        if (data.type != JSONType.object)
            return false;

        foreach (field; ["id", "ts", "from", "text"])
        {
            if (field !in data.object)
                return false;
        }

        if (data["id"].type != JSONType.string || data["from"].type != JSONType.string ||
            data["text"].type != JSONType.string || data["ts"].type != JSONType.integer)
            return false;

        entry.id = data["id"].str.idup;
        entry.timestamp = data["ts"].integer;
        entry.from = data["from"].str.idup;
        entry.text = data["text"].str.idup;
        if ("to" in data.object && data["to"].type == JSONType.string)
            entry.to = data["to"].str.idup;

        if ("room" in data.object && data["room"].type == JSONType.string)
            entry.room = data["room"].str.idup;

        return true;
    }

public:
    /// Stable identifier for the entry.
    string id;
    /// Millisecond epoch of the post.
    long timestamp;
    /// Profile name of the sender.
    string from;
    /// Message text.
    string text;
    /// Recipient profile name for a direct message.
    string to;
    /// Room name for a room message.
    string room;

    /// Creates an entry for a sender with optional routing.
    static Entry create(string from, string text, string to = null, string room = null)
    {
        Entry ret;
        ret.id = randomUUID().toString();
        ret.timestamp = Clock.currTime(UTC()).stdTime / HNSSECS_PER_MSEC;
        ret.from = from;
        ret.text = text;
        ret.to = to;
        ret.room = room;
        return ret;
    }

    /// Serializes the entry, omitting absent routing.
    JSONValue toJSON()
    {
        JSONValue ret = JSONValue.emptyObject;
        ret["id"] = JSONValue(id);
        ret["ts"] = JSONValue(timestamp);
        ret["from"] = JSONValue(from);
        ret["text"] = JSONValue(text);
        if (to.length)
            ret["to"] = JSONValue(to);

        if (room.length)
            ret["room"] = JSONValue(room);

        return ret;
    }
}

/// An append-only message log with its most recent entries held in memory.
class Stream
{
private:
    Entry[] window;

    static bool parse(string line, out Entry entry)
    {
        JSONValue data;
        try
            data = parseJSON(line);
        catch (Exception)
            return false;

        return Entry.parse(data, entry);
    }

    void load()
    {
        if (!exists(path))
            return;

        File file = openFile(path, O_RDONLY);
        scope(exit)
            file.close();

        bool tail;
        if (file.size > MAX_LOG_BYTES)
        {
            file.seek(cast(long)file.size - MAX_LOG_BYTES);
            tail = true;
        }

        string content = cast(string)file.byChunk(4096).join;
        if (tail)
        {
            size_t start = content.indexOf('\n');
            content = start < 0 ? null : content[start + 1 .. $];
        }

        Entry[] loaded;
        if (content.length)
        {
            foreach (line; content.splitLines())
            {
                Entry entry;
                if (parse(line, entry))
                    loaded ~= entry;
            }
        }

        window = loaded.length <= MAX_ENTRIES ? loaded : loaded[$ - MAX_ENTRIES .. $];
    }

public:
    /// Stream key, such as room:general, dms:marlow, or pings:marlow.
    const string name;
    /// Path of the append-only log.
    const string path;

    this(string name, string path)
    {
        this.name = name.idup;
        this.path = path.idup;
        load();
    }

    /// Entries held in memory, oldest first.
    Entry[] entries()
        => window;

    /// Entries at or after an in-memory position.
    Entry[] since(size_t position)
    {
        if (position >= window.length)
            return null;

        return window[position .. $];
    }

    /// Appends an entry to the log and to the window.
    void append(Entry entry)
    {
        mkdirRecurse(dirName(path));
        File file = openFile(path, O_RDWR | O_CREAT | O_APPEND);
        scope(exit)
            file.close();

        file.write(entry.toJSON().toString());
        file.write("\n");
        file.flush();
        window ~= entry;
        if (window.length > MAX_ENTRIES)
            window = window[$ - MAX_ENTRIES .. $];
    }
}
