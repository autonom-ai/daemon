/// Stable coordination message values shared by storage and transport.
module daemon.coord.entry;

import std.datetime : Clock, UTC;
import std.json : JSONType, JSONValue;
import std.uuid : randomUUID;

enum stdTimeTicksPerMillisecond = 10_000;

/// One coordination message independent of its persistence or transport.
struct Entry
{
    string id;
    long timestamp;
    string from;
    string text;
    string to;
    string room;

    /// Create a message with a generated identifier and current UTC timestamp.
    static Entry create(string from, string text, string to = null, string room = null)
    {
        Entry ret;
        ret.id = randomUUID().toString();
        ret.timestamp = Clock.currTime(UTC()).stdTime / stdTimeTicksPerMillisecond;
        ret.from = from;
        ret.text = text;
        ret.to = to;
        ret.room = room;
        return ret;
    }

    /// Encode the message fields used by coordination storage and transport.
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

    /// Decode one persisted message, rejecting malformed required fields.
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

}
