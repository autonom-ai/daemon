module daemon.coord.stream;

import daemon.storage;

import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDONLY, O_RDWR;
import std.array : join;
import std.datetime : Clock, UTC;
import std.file;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : dirName;
import std.stdio : File;
import std.string : indexOf, splitLines;
import std.uuid;

public:

enum MAX_ENTRIES = 1000;
enum MAX_LOG_BYTES = 4 * 1024 * 1024;
enum HECTONANOSECONDS_PER_MILLISECOND = 10_000;

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
    string id;
    long timestamp;
    string from;
    string text;
    string to;
    string room;

    static Entry create(string from, string text, string to = null, string room = null)
    {
        Entry ret;
        ret.id = randomUUID().toString();
        ret.timestamp = Clock.currTime(UTC()).stdTime / HECTONANOSECONDS_PER_MILLISECOND;
        ret.from = from;
        ret.text = text;
        ret.to = to;
        ret.room = room;
        return ret;
    }

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
    const string name;
    const string path;

    this(string name, string path)
    {
        this.name = name.idup;
        this.path = path.idup;
        load();
    }

    Entry[] entries()
        => window;

    Entry[] since(size_t position)
    {
        if (position >= window.length)
            return null;

        return window[position .. $];
    }

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
