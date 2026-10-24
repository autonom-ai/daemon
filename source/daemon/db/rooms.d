/// Persistent room authority snapshots; mutation policy belongs to coordination operations.
module daemon.db.rooms;

import daemon.db : Connection;
import daemon.exception : ConflictException, InvalidInputException;

import arsd.sqlite : ResultSet, Row;

import std.typecons : Nullable;

/// A detached snapshot; an unrestricted room has no involved-member restriction.
struct StoredRoom
{
    string name;
    string owner;
    string[] admins;
    string[] involved;
    bool restricted;
}

/// Room facts on the borrowed worker-owned domain connection.
class Rooms
{
private:
    Connection connection;

public:
    /// Borrow a connection owned by the domain worker.
    this(Connection connection)
    {
        this.connection = connection;
    }

    /// Create membership and its message stream in one transition.
    void create(StoredRoom room)
    {
        requireValid(room);
        connection.transaction({
            connection.query("insert into rooms(name, owner, restricted) values (?, ?, ?)",
                room.name, room.owner, room.restricted ? 1 : 0);
            membership(room);
            connection.query("insert into streams(name, room) values (?, ?)", "room:"~room.name, room.name);
        });
    }

    /// Return all rooms in canonical order with independent membership arrays.
    StoredRoom[] list()
    {
        ResultSet rows = connection.query("select name, owner, restricted from rooms order by name");
        scope(exit)
            destroy(rows);
        StoredRoom[] ret;
        foreach (Row row; rows)
            ret ~= snapshot(row);
        return ret;
    }

    /// Find a room without exposing query-backed values or acquiring any backend.
    Nullable!StoredRoom get(string name)
    {
        ResultSet rows = connection.query("select name, owner, restricted from rooms where name = ?", name);
        scope(exit)
            destroy(rows);
        return rows.empty ? Nullable!StoredRoom.init : Nullable!StoredRoom(snapshot(rows.front));
    }

    /// Replace membership atomically; the room must exist and ownership is not transferable.
    void update(StoredRoom room)
    {
        requireValid(room);
        connection.transaction({
            ResultSet owner = connection.query("select owner from rooms where name = ?", room.name);
            scope(exit)
                destroy(owner);
            if (owner.empty)
                throw new ConflictException("Room does not exist");
            if (owner.front["owner"].toString != room.owner)
                throw new ConflictException("Room ownership cannot be transferred");
            connection.query("update rooms set restricted = ? where name = ?", room.restricted ? 1 : 0, room.name);
            connection.query("delete from room_members where room = ?", room.name);
            membership(room);
        });
    }

    /// Delete the room, message stream, and all read positions together.
    void remove(string name)
    {
        connection.transaction({
            connection.query("delete from rooms where name = ?", name);
        });
    }

private:
    void requireValid(StoredRoom room)
    {
        if (!room.restricted && room.involved.length)
            throw new InvalidInputException("Unrestricted rooms cannot carry involved members");
    }

    void membership(StoredRoom room)
    {
        foreach (name; room.admins)
            connection.query("insert into room_members(room, profile, role) values (?, ?, 'admin')", room.name, name);
        if (room.restricted)
        {
            foreach (name; room.involved)
                connection.query("insert into room_members(room, profile, role) values (?, ?, 'member')", room.name, name);
        }
    }

    StoredRoom snapshot(Row row)
    {
        StoredRoom ret;
        ret.name = row["name"].toString.idup;
        ret.owner = row["owner"].toString.idup;
        ret.restricted = row["restricted"].toString == "1";
        ResultSet members = connection.query("select profile, role from room_members where room = ? order by profile", ret.name);
        scope(exit)
            destroy(members);
        foreach (Row member; members)
        {
            if (member["role"].toString == "admin")
                ret.admins ~= member["profile"].toString.idup;
            else
                ret.involved ~= member["profile"].toString.idup;
        }
        return ret;
    }
}
