/// Worker-owned per-actor stream read positions.
module daemon.db.cursors;

import daemon.db : Connection;
import daemon.exception : InvalidInputException;

import arsd.sqlite : ResultSet;

import std.conv : to;
import std.typecons : Nullable;

/// Monotonic read cursors on the borrowed worker-owned domain connection.
class Cursors
{
private:
    Connection connection;

public:
    /// Borrow a connection owned by the domain worker.
    this(Connection connection)
    {
        this.connection = connection;
    }

    /// Read the stored cursor; absent and explicit zero are distinct states.
    Nullable!long get(string profile, string stream)
    {
        ResultSet rows = connection.query(
            "select sequence from cursors where profile = ? and stream = ?", profile, stream);
        scope(exit)
            destroy(rows);
        return rows.empty ? Nullable!long.init : Nullable!long(rows.front["sequence"].toString.to!long);
    }

    /// Advance without rewinding; rejects negative or unwritten sequences.
    void advance(string profile, string stream, long sequence)
    {
        if (sequence < 0)
            throw new InvalidInputException("Negative cursor");
        connection.transaction({
            ResultSet allocated = connection.query("select next_sequence from streams where name = ?", stream);
            scope(exit)
                destroy(allocated);
            if (allocated.empty)
                throw new InvalidInputException("Unknown stream");
            if (sequence >= allocated.front["next_sequence"].toString.to!long)
                throw new InvalidInputException("Cursor exceeds the stream tail");
            connection.query(
                "insert into cursors(profile, stream, sequence) values (?, ?, ?) "~
                "on conflict(profile, stream) do update set sequence = max(cursors.sequence, excluded.sequence)",
                profile, stream, sequence);
        });
    }
}
