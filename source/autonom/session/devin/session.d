module autonom.session.devin.session;

import autonom.session.devin.bridge : Devin;
import autonom.session.session : Session;
import autonom.storage : openFile;

import core.stdc.errno : errno, EWOULDBLOCK;
import core.sys.posix.fcntl : O_RDONLY;
import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB;
import std.exception : errnoEnforce;
import std.file : exists;
import std.path : buildPath;
import std.stdio : File;

public:

class DevinSession : Session
{
private:
    string lockPath;

protected:
    override string[] resumeArguments(string prompt, string model)
        => ["--resume", id]~Devin.arguments(prompt, model);

public:
    this(string id, Devin bridge)
    {
        super(id, bridge);
        lockPath = buildPath(bridge.sessionLockDir, id~".lock");
    }

    override bool isOnline()
    {
        if (!exists(lockPath))
            return false;

        File file = openFile(lockPath, O_RDONLY);
        scope(exit)
            file.close();

        int result = flock(file.fileno, LOCK_EX | LOCK_NB);
        errnoEnforce(result == 0 || errno == EWOULDBLOCK, "Could not inspect session lock");
        return result != 0;
    }
}
