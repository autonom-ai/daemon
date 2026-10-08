module autonom.storage;

import core.sys.posix.fcntl : open, O_CLOEXEC, O_CREAT, O_EXCL, O_NOFOLLOW, O_NONBLOCK, O_RDWR;
import core.sys.posix.sys.stat : fstat, stat_t, S_IFMT, S_IFREG;
import core.sys.posix.unistd : close, fsync;
import std.conv : octal;
import std.exception : enforce, errnoEnforce;
import std.file : exists, isSymlink, remove, rename;
import std.path : dirName;
import std.stdio : File;
import std.string : toStringz;
import std.uuid : randomUUID;

package(autonom):

File openFile(string path, int flags)
{
    enforce(!isSymlink(dirName(path)), "Storage directory must not be a symlink");
    int descriptor = open(path.toStringz, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, octal!"600");
    errnoEnforce(descriptor >= 0, "Could not open storage file");
    scope(failure)
        close(descriptor);

    stat_t attributes;
    errnoEnforce(fstat(descriptor, &attributes) == 0, "Could not inspect storage file");
    enforce((attributes.st_mode & S_IFMT) == S_IFREG, "Storage must be a regular file");
    File ret;
    ret.fdopen(descriptor, (flags & O_RDWR) ? "r+" : "r");
    return ret;
}

void atomicWrite(string path, string content)
{
    string temporary = path~"."~randomUUID().toString()~".tmp";
    File file = openFile(temporary, O_RDWR | O_CREAT | O_EXCL);
    scope(exit)
    {
        file.close();
        if (exists(temporary))
            remove(temporary);
    }

    file.write(content);
    file.flush();
    errnoEnforce(fsync(file.fileno) == 0, "Could not flush storage file");
    rename(temporary, path);
}
