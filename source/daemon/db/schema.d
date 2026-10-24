/// Versioned schema for Autonom-owned facts, never for the provider's catalog.
module daemon.db.schema;

import arsd.sqlite : Sqlite, queryOneColumn;

import std.conv : to;

package(daemon.db):

enum applicationId = 0x4155544F;
enum schemaVersion = 1;

void migrate(Sqlite connection)
{
    int storedVersion = connection.queryOneColumn!int("pragma user_version");
    int identity = connection.queryOneColumn!int("pragma application_id");
    if (storedVersion == schemaVersion && identity == applicationId)
        return;
    if (storedVersion != 0 || identity != 0)
        throw new Exception("Unsupported Autonom database identity or schema version");

    connection.query("begin immediate");
    scope(failure)
        connection.query("rollback");

    storedVersion = connection.queryOneColumn!int("pragma user_version");
    identity = connection.queryOneColumn!int("pragma application_id");
    if (storedVersion == schemaVersion && identity == applicationId)
    {
        connection.query("commit");
        return;
    }
    if (storedVersion != 0 || identity != 0 ||
        connection.queryOneColumn!long("select count(*) from sqlite_master where name not like 'sqlite_%'") != 0)
        throw new Exception("Refusing to initialize a nonempty or unsupported database");

    connection.query(
        "create table profiles ("~
        "name text primary key not null check(length(name) between 1 and 64 and "~
        "name glob '[a-z0-9]*' and name not glob '*[^a-z0-9_-]*' and name != 'human'))"
    );
    connection.query(
        "create table session_associations ("~
        "provider text not null check(length(provider) between 1 and 32 and "~
        "provider glob '[a-z]*' and provider not glob '*[^a-z0-9_-]*'), "~
        "session_id text not null check(length(session_id) between 1 and 128 and "~
        "session_id glob '[A-Za-z0-9]*' and session_id not glob '*[^A-Za-z0-9_-]*'), "~
        "profile_name text not null references profiles(name) on delete restrict, "~
        "primary key(provider, session_id), unique(profile_name, provider, session_id))"
    );
    connection.query(
        "create table profile_bindings ("~
        "profile_name text primary key not null references profiles(name) on delete restrict, "~
        "provider text, session_id text, unique(provider, session_id), "~
        "check((provider is null and session_id is null) or (provider is not null and session_id is not null)), "~
        "foreign key(profile_name, provider, session_id) "~
        "references session_associations(profile_name, provider, session_id) on delete restrict)"
    );
    connection.query(
        "create table imports (domain text primary key not null, "~
        "source_version integer not null, source text not null)"
    );
    connection.query("pragma application_id = "~applicationId.to!string);
    connection.query("pragma user_version = "~schemaVersion.to!string);
    connection.query("commit");
}
