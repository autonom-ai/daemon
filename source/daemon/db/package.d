/// Worker-owned persistence for Autonom domain facts; not yet enabled in production assembly.
module daemon.db;

import daemon.db.schema : migrate;
import daemon.storage : openFile;

import arsd.sqlite : ResultSet, Sqlite, SQLITE_OPEN_READWRITE;

import core.stdc.errno : errno, ENOENT;
import core.sys.posix.fcntl : O_CREAT, O_EXCL, O_RDWR;
import core.sys.posix.sys.stat : lstat, stat_t, S_ISDIR, S_ISREG;
import core.sys.posix.unistd : getuid;
import core.thread : Thread;
import std.conv : octal;
import std.file : exists, mkdirRecurse, setAttributes;
import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.process : thisProcessID;
import std.stdio : File;
import std.string : toStringz;

/// One explicit-close connection bound to its creating worker process and thread.
class Connection
{
private:
    Sqlite connection;
    Thread owner;
    int process;
    bool active;
    bool poisoned;

public:
    const string path;

    this(string dataDirectory)
    {
        owner = Thread.getThis();
        process = thisProcessID;
        string directory = buildNormalizedPath(absolutePath(dataDirectory));
        if (!exists(directory))
        {
            mkdirRecurse(directory);
            setAttributes(directory, octal!"700");
        }
        requirePath(directory, true);
        path = buildPath(directory, "autonom.db");
        stat_t attributes;
        if (lstat(path.toStringz, &attributes) != 0)
        {
            if (errno != ENOENT)
                throw new Exception("Cannot inspect the Autonom database path");

            File created = openFile(path, O_RDWR | O_CREAT | O_EXCL);
            created.close();
        }
        requirePath(path, false);

        // The bundled arsd version does not declare SQLite's OPEN_NOFOLLOW flag.
        enum sqliteOpenNoFollow = 0x01000000;
        connection = new Sqlite(path, SQLITE_OPEN_READWRITE | sqliteOpenNoFollow);
        scope(failure)
            close();

        connection.query("pragma busy_timeout = 250");
        connection.query("pragma foreign_keys = on");
        migrate(connection);
        connection.query("pragma journal_mode = wal");
    }

    /// Commit one transition or roll it back; nested transitions are rejected explicitly.
    void transaction(scope void delegate() operation)
    {
        requireOwner();
        if (active)
            throw new Exception("Nested domain transactions are not supported");

        query("begin immediate");
        active = true;
        scope(exit)
            active = false;
        try
        {
            operation();
            query("commit");
        }
        catch (Exception failure)
        {
            try
                query("rollback");
            catch (Exception rollback)
            {
                poisoned = true;
                throw new Exception("Domain database rollback failed: "~rollback.msg, __FILE__, __LINE__, failure);
            }
            throw failure;
        }
    }

    /// Close after domain owners stop using the connection; safe to repeat on the owner.
    void close()
    {
        requireOwner();
        if (active)
            throw new Exception("Cannot close a database during a transition");
        if (connection !is null)
        {
            destroy(connection);
            connection = null;
        }
    }

package(daemon.db):
    ResultSet query(Args...)(string sql, Args args)
    {
        requireOwner();
        if (connection is null || poisoned)
            throw new Exception("The domain database is closed or unusable");

        return connection.query(sql, args);
    }

private:
    void requireOwner()
    {
        if (Thread.getThis() !is owner || thisProcessID != process)
            throw new Exception("Domain database access requires its owning worker");
    }

    static void requirePath(string path, bool directory)
    {
        stat_t attributes;
        if (lstat(path.toStringz, &attributes) != 0 || attributes.st_uid != getuid() ||
            (directory ? !S_ISDIR(attributes.st_mode) : !S_ISREG(attributes.st_mode)) ||
            (attributes.st_mode & (directory ? octal!"022" : octal!"077")) != 0)
            throw new Exception("Domain database paths must be user-owned, non-symlinked, and private for writing");
    }
}
