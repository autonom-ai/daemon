module daemon.storage;

import core.sys.posix.fcntl;
import core.sys.posix.sys.stat : fstat, stat_t, S_IFMT, S_IFREG;
import core.sys.posix.unistd : close, fsync;
import std.conv : octal;
import std.exception : ErrnoException;
import std.file;
import std.json : JSONValue, parseJSON;
import std.path : dirName;
import std.stdio : File;
import std.string : toStringz;
import std.uuid;

package(daemon):

File openFile(string path, int flags)
{
    if (isSymlink(dirName(path)))
        throw new Exception("Storage directory must not be a symlink");

    int descriptor = open(path.toStringz, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, octal!"600");
    if (descriptor < 0)
        throw new ErrnoException("Could not open storage file");

    scope(failure)
        close(descriptor);

    stat_t attributes;
    if (fstat(descriptor, &attributes) != 0)
        throw new ErrnoException("Could not inspect storage file");
    if ((attributes.st_mode & S_IFMT) != S_IFREG)
        throw new Exception("Storage must be a regular file");
    File ret;
    ret.fdopen(descriptor, (flags & O_RDWR) ? "r+" : "r");
    return ret;
}

string readText(string path, size_t limit = 64 * 1024)
{
    File file = openFile(path, O_RDONLY);
    scope(exit)
        file.close();

    if (file.size > limit)
        throw new Exception("Storage file is too large");

    string ret;
    foreach (chunk; file.byChunk(4096))
    {
        if (chunk.length > limit - ret.length)
            throw new Exception("Storage file is too large");

        ret ~= cast(char[])chunk;
    }

    return ret;
}

JSONValue readJSON(string path, size_t limit = 64 * 1024)
{
    string content = readText(path, limit);
    try
        return parseJSON(content);
    catch (Exception error)
        throw new FileException(path, error.msg);
}

void atomicWrite(string path, string content)
{
    bool committed;
    atomicWrite(path, content, committed);
}

void atomicWrite(string path, string content, out bool committed)
{
    committed = false;
    if (exists(path) && isSymlink(path))
        throw new Exception("Storage file must not be a symlink");

    int directory = open(dirName(path).toStringz, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0)
        throw new ErrnoException("Could not open storage directory");

    scope(exit)
        close(directory);

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
    if (fsync(file.fileno) != 0)
        throw new ErrnoException("Could not flush storage file");

    rename(temporary, path);
    committed = true;
    if (fsync(directory) != 0)
        throw new ErrnoException("Could not flush storage directory");
}
