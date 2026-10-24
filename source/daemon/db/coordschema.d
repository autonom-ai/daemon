/// Coordination schema, installed atomically with the enclosing schema version.
module daemon.db.coordschema;

import arsd.sqlite : Sqlite;

package(daemon.db) void migrateCoordination(Sqlite connection)
{
    connection.query(
        "create table actors ("~
        "name text primary key not null, "~
        "profile_name text unique references profiles(name) on delete restrict, "~
        "check((name = 'human' and profile_name is null) or "~
        "(name != 'human' and profile_name is not null and profile_name = name)))"
    );
    connection.query("insert into actors(name, profile_name) values ('human', null)");
    connection.query("insert into actors(name, profile_name) select name, name from profiles");
    connection.query(
        "create trigger profile_actor after insert on profiles "~
        "begin insert into actors(name, profile_name) values (new.name, new.name); end"
    );
    connection.query(
        "create table rooms ("~
        "name text primary key not null check(length(name) between 1 and 64 and "~
        "name glob '[a-z0-9]*' and name not glob '*[^a-z0-9_-]*'), "~
        "owner text not null references actors(name), "~
        "restricted integer not null check(restricted in (0,1)))"
    );
    connection.query(
        "create table room_members ("~
        "room text not null references rooms(name) on delete cascade, "~
        "profile text not null references actors(name), "~
        "role text not null check(role in ('admin','member')), "~
        "primary key(room, profile, role))"
    );
    connection.query(
        "create table streams ("~
        "name text primary key not null, "~
        "room text references rooms(name) on delete cascade, "~
        "profile text references actors(name) on delete restrict, "~
        "next_sequence integer not null default 1 check(typeof(next_sequence) = 'integer' and next_sequence > 0), "~
        "check((room is null) != (profile is null) and "~
        "((room is not null and name = 'room:'||room) or "~
        "(profile is not null and (name = 'dm:'||profile or name = 'ping:'||profile)))))"
    );
    connection.query(
        "create table messages ("~
        "stream text not null references streams(name) on delete cascade, "~
        "sequence integer not null check(typeof(sequence) = 'integer' and sequence > 0), "~
        "id text not null check(length(id) > 0), "~
        "timestamp integer not null, "~
        "sender text not null references actors(name), "~
        "text text not null, "~
        "recipient text, "~
        "room text, "~
        "bytes integer not null check(typeof(bytes) = 'integer' and bytes >= 0), "~
        "primary key(stream, sequence), unique(stream, id))"
    );
    connection.query(
        "create table cursors ("~
        "profile text not null references actors(name), "~
        "stream text not null references streams(name) on delete cascade, "~
        "sequence integer not null check(typeof(sequence) = 'integer' and sequence >= 0), "~
        "primary key(profile, stream))"
    );
}
