module daemon.coord.stream;

public import daemon.coord.entry : Entry, stdTimeTicksPerMillisecond;

import daemon.storage;

import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_RDONLY, O_RDWR;
import std.array : join;
import std.file;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : dirName;
import std.stdio : File;
import std.string : indexOf, splitLines;

enum defaultMaxEntries = 1000;
enum defaultMaxLogBytes = 4 * 1024 * 1024;

private bool isSymlinkSafe(string target)
{
    try
        return isSymlink(target);
    catch (Exception)
        return false;
}

class Stream
{
private:
    Entry[] window;
    size_t entriesOnDisk;

public:
    const string name;
    const string path;
    const size_t maxBytes;
    const size_t maxEntries;

    this(string name, string path, size_t maxBytes = defaultMaxLogBytes, size_t maxEntries = defaultMaxEntries)
    {
        this.name = name.idup;
        this.path = path.idup;
        this.maxBytes = maxBytes;
        this.maxEntries = maxEntries;
        load();
    }

    Entry[] entries()
        => window;

    Entry[] since(size_t position)
    {
        if (position >= window.length)
            return null;

        return window[position..$];
    }

    void append(Entry entry)
    {
        mkdirRecurse(dirName(path));
        File file = openFile(path, O_RDWR | O_CREAT | O_APPEND);
        if (entriesOnDisk >= maxEntries || file.size >= maxBytes)
        {
            file.close();
            string rotated = path~".1";
            if (isSymlinkSafe(rotated))
                throw new Exception("Storage file must not be a symlink");

            rename(path, rotated);
            entriesOnDisk = 0;
            file = openFile(path, O_RDWR | O_CREAT | O_APPEND);
        }

        scope(exit)
            file.close();

        file.write(entry.toJSON().toString());
        file.write("\n");
        file.flush();
        entriesOnDisk++;

        window ~= entry;
        if (window.length > maxEntries)
            window = window[$-maxEntries..$];
    }

private:
    static bool parse(string line, out Entry entry)
    {
        JSONValue data;
        try
            data = parseJSON(line);
        catch (Exception)
            return false;

        return Entry.parse(data, entry);
    }

    Entry[] readEntries(string targetPath, size_t byteLimit)
    {
        if (!exists(targetPath))
            return null;

        if (isSymlinkSafe(targetPath))
            throw new Exception("Storage file must not be a symlink");

        File file = openFile(targetPath, O_RDONLY);
        scope(exit)
            file.close();

        bool tail;
        if (file.size > byteLimit)
        {
            file.seek(cast(long)file.size - byteLimit);
            tail = true;
        }

        string content = cast(string)file.byChunk(4096).join;
        if (tail)
        {
            ptrdiff_t start = content.indexOf('\n');
            content = (start < 0 || start + 1 >= content.length) ? null : content[start + 1..$];
        }

        Entry[] ret;
        if (content.length)
        {
            foreach (line; content.splitLines())
            {
                Entry entry;
                if (parse(line, entry))
                    ret ~= entry;
            }
        }

        return ret;
    }

    void load()
    {
        Entry[] loaded;
        if (exists(path))
        {
            if (isSymlinkSafe(path))
                throw new Exception("Storage file must not be a symlink");

            Entry[] current = readEntries(path, maxBytes);
            entriesOnDisk = current.length;
            if (current.length < maxEntries)
            {
                string rotated = path~".1";
                if (exists(rotated))
                {
                    if (isSymlinkSafe(rotated))
                        throw new Exception("Storage file must not be a symlink");

                    loaded = readEntries(rotated, maxBytes)~current;
                }
                else
                    loaded = current;
            }
            else
                loaded = current;
        }
        else
        {
            entriesOnDisk = 0;
            string rotated = path~".1";
            if (exists(rotated))
            {
                if (isSymlinkSafe(rotated))
                    throw new Exception("Storage file must not be a symlink");

                loaded = readEntries(rotated, maxBytes);
            }
        }

        window = loaded.length <= maxEntries ? loaded : loaded[$-maxEntries..$];
    }
}
