module daemon.interop.devin.catalog;

import daemon.interop.devin.db : readSessionCatalog, readSessionMessages, readSessionMetadata;
import daemon.interop.metadata : SessionMetadata;
import daemon.interop.session : Session;
import daemon.exception : ConflictException;
import daemon.storage : openFile;

import core.stdc.errno : errno, EWOULDBLOCK;
import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB;
import core.sys.posix.fcntl : O_RDONLY;
import std.algorithm : sort;
import std.exception : ErrnoException;
import std.file : exists;
import std.json : JSONValue;
import std.path : buildPath, dirName;
import std.stdio : File;

bool heldLock(string path)
{
    if (!exists(path))
        return false;

    File file = openFile(path, O_RDONLY);
    scope(exit)
        file.close();

    int result = flock(file.fileno, LOCK_EX | LOCK_NB);
    if (result != 0 && errno != EWOULDBLOCK)
        throw new ErrnoException("Could not inspect session lock");

    return result != 0;
}

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
                else if (databaseFor(entry.id) == localDatabase)
                {
                    foreach (ref existing; ret)
                    {
                        if (existing.id == entry.id)
                            existing = entry;
                    }
                }
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
        return readSessionMetadata(databaseFor(id), id);
    }

    string databaseFor(string id) const
    {
        if (!id.length)
            return database;

        Session.validateId(id);
        bool managedHeld = heldLock(buildPath(dirName(database), "session_locks", id~".lock"));
        bool nativeHeld = localDatabase != database && heldLock(buildPath(localLockDirectory, id~".lock"));
        if (managedHeld && nativeHeld)
            throw new ConflictException("Session ID is loaded in both catalogs");
        if (managedHeld)
            return database;
        if (nativeHeld)
            return localDatabase;

        if (readSessionMetadata(database, id).id.length)
            return database;
        if (localDatabase != database && readSessionMetadata(localDatabase, id).id.length)
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
