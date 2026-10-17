module daemon.interop.devin.session.catalog;

import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.connection : observedDirectory;
import daemon.interop.devin.db : readSessionMetadata;
import daemon.interop.devin.session : Session;
import daemon.interop.metadata : SessionMetadata;
import daemon.storage : openFile;

import core.stdc.errno : errno, EWOULDBLOCK;
import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB;
import core.sys.posix.fcntl : O_RDONLY;
import std.exception : ErrnoException;
import std.file : exists;
import std.path : buildPath;
import std.stdio : File;

bool online(Bridge owner, string id)
{
    Session.validateId(id);
    string path = owner.lockPath(id);
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

SessionMetadata sessionMetadata(Bridge owner, string id)
{
    Session.validateId(id);
    SessionMetadata ret = readSessionMetadata(owner.sessionDatabase, id);

    if (!ret.id.length)
        ret.directory = owner.observedDirectory(id);

    return ret;
}

string lockPath(const Bridge owner, string id)
    => buildPath(owner.sessionLockDir, id~".lock");
