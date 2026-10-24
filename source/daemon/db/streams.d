/// Worker-owned bounded message streams keyed by absolute sequence.
module daemon.db.streams;

import daemon.coord.entry : Entry;
import daemon.db : Connection;
import daemon.exception : InvalidInputException;

import arsd.sqlite : ResultSet, Row;

import std.conv : to;

/// One stored message with its absolute position in the stream.
struct StoredEntry
{
    long sequence;
    Entry entry;
}

/// Bounded message storage on the borrowed worker-owned domain connection.
class Streams
{
private:
    Connection connection;
    size_t maxEntries;
    size_t maxBytes;

public:
    /// Borrow a connection and enforce positive retained-entry and byte bounds.
    this(Connection connection, size_t maxEntries, size_t maxBytes)
    {
        if (maxEntries == 0 || maxEntries > long.max || maxBytes == 0 || maxBytes > long.max)
            throw new InvalidInputException("Stream bounds must be positive integers");
        this.connection = connection;
        this.maxEntries = maxEntries;
        this.maxBytes = maxBytes;
    }

    /// Idempotently create the direct or ping inbox stream for an existing actor.
    void ensureInbox(string profile, bool urgent = false)
    {
        connection.transaction({
            connection.query("insert or ignore into streams(name, profile) values (?, ?)",
                (urgent ? "ping:" : "dm:")~profile, profile);
        });
    }

    /// Append one entry at the allocated sequence, then trim to the bounded suffix.
    long append(string stream, Entry entry)
    {
        long bytes = entry.toJSON().toString().length + 1;
        if (bytes > cast(long)maxBytes)
            throw new InvalidInputException("Entry exceeds the stream byte bound");

        long sequence;
        connection.transaction({
            ResultSet allocated = connection.query("select next_sequence from streams where name = ?", stream);
            scope(exit)
                destroy(allocated);
            if (allocated.empty)
                throw new InvalidInputException("Unknown stream");
            sequence = allocated.front["next_sequence"].toString.to!long;
            if (sequence >= long.max)
                throw new InvalidInputException("Stream sequence exhausted");
            connection.query(
                "insert into messages(stream, sequence, id, timestamp, sender, text, recipient, room, bytes) "~
                "values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                stream, sequence, entry.id, entry.timestamp, entry.from, entry.text,
                entry.to.length ? entry.to : null, entry.room.length ? entry.room : null, bytes);
            connection.query("update streams set next_sequence = next_sequence + 1 where name = ?", stream);
            trim(stream);
        });
        return sequence;
    }

    /// Read entries after an absolute cursor in ascending order, capped by the bound.
    StoredEntry[] read(string stream, long after = 0, size_t limit = 100)
    {
        if (after < 0)
            throw new InvalidInputException("Negative stream cursor");
        if (limit > maxEntries)
            limit = maxEntries;

        StoredEntry[] ret;
        ResultSet rows = connection.query(
            "select sequence, id, timestamp, sender, text, "~
            "coalesce(recipient, '') as recipient, coalesce(room, '') as room from messages "~
            "where stream = ? and sequence > ? order by sequence limit ?",
            stream, after, cast(long)limit);
        scope(exit)
            destroy(rows);
        foreach (Row row; rows)
        {
            StoredEntry stored;
            stored.sequence = row["sequence"].toString.to!long;
            stored.entry.id = row["id"].toString.idup;
            stored.entry.timestamp = row["timestamp"].toString.to!long;
            stored.entry.from = row["sender"].toString.idup;
            stored.entry.text = row["text"].toString.idup;
            string recipient = row["recipient"];
            if (recipient.length)
                stored.entry.to = recipient.idup;
            string room = row["room"];
            if (room.length)
                stored.entry.room = room.idup;
            ret ~= stored;
        }
        return ret;
    }

private:
    void trim(string stream)
    {
        ResultSet rows = connection.query(
            "select sequence, bytes from messages where stream = ? order by sequence desc limit ?",
            stream, cast(long)maxEntries);
        scope(exit)
            destroy(rows);
        long total;
        long cutoff = -1;
        size_t kept;
        foreach (Row row; rows)
        {
            if (kept == maxEntries)
                break;
            long bytes = row["bytes"].toString.to!long;
            if (bytes > cast(long)maxBytes - total)
                break;
            total += bytes;
            cutoff = row["sequence"].toString.to!long;
            kept++;
        }
        if (cutoff >= 0)
            connection.query("delete from messages where stream = ? and sequence < ?", stream, cutoff);
    }
}
