module autonom.interop.devin.db;

import arsd.sqlite;

import std.file : exists;

public:

struct SessionMetadata
{
    string model;
    string directory;
}

SessionMetadata readSessionMetadata(string database, string id)
{
    SessionMetadata ret;
    if (!database.length || !exists(database))
        return ret;

    Database connection = new Sqlite(database, SQLITE_OPEN_READONLY);
    ResultSet result = connection.query("select model, working_directory from sessions where id = ?", id);
    if (result.empty)
        return ret;

    Row row = result.front;
    ret.model = row["model"].toString();
    ret.directory = row["working_directory"].toString();
    return ret;
}
