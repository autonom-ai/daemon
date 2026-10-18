module daemon.interop.devin.catalog;

import daemon.interop.devin.db : readSessionCatalog, readSessionMessages, readSessionMetadata;
import daemon.interop.metadata : SessionMetadata;
import daemon.interop.session : Session;

import std.algorithm : sort;
import std.file : exists;
import std.json : JSONValue;
import std.path : buildPath, dirName;

/// Read both CLI catalogs without granting control or moving sessions between them.
class Catalog
{
    const string database;
    const string localDatabase;
    const string localLockDirectory;

    this(string database, string localDatabase, string localLockDirectory)
    {
        this.database = database;
        this.localDatabase = localDatabase;
        this.localLockDirectory = localLockDirectory;
    }

    SessionMetadata[] list() const
    {
        SessionMetadata[] ret = readSessionCatalog(database);
        bool[string] seen;
        foreach (entry; ret)
            seen[entry.id] = true;

        if (localDatabase != database)
        {
            foreach (entry; readSessionCatalog(localDatabase))
            {
                if (entry.id !in seen)
                    ret ~= entry;
            }
        }

        ret.sort!((left, right) {
            return left.createdAt == right.createdAt ? left.id < right.id : left.createdAt < right.createdAt;
        });
        return ret;
    }

    SessionMetadata metadata(string id) const
    {
        Session.validateId(id);
        SessionMetadata ret = readSessionMetadata(database, id);
        if (!ret.id.length && localDatabase != database)
            ret = readSessionMetadata(localDatabase, id);

        return ret;
    }

    string databaseFor(string id) const
    {
        if (!id.length)
            return database;

        Session.validateId(id);
        if (readSessionMetadata(database, id).id.length)
            return database;
        if (localDatabase != database && readSessionMetadata(localDatabase, id).id.length)
            return localDatabase;
        if (exists(buildPath(dirName(database), "session_locks", id~".lock")))
            return database;
        if (exists(buildPath(localLockDirectory, id~".lock")))
            return localDatabase;

        return database;
    }

    string lockPath(string id) const
    {
        string selected = databaseFor(id);
        string directory = selected == localDatabase
            ? localLockDirectory
            : buildPath(dirName(selected), "session_locks");
        return buildPath(directory, id~".lock");
    }

    JSONValue messages(string id, size_t limit = 300) const
        => readSessionMessages(databaseFor(id), id, limit);
}
