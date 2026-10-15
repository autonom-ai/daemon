module daemon.interop.acp.frames;

import core.atomic : atomicLoad;
import core.stdc.errno : errno, EINTR;
import core.sys.posix.poll : poll, pollfd, POLLOUT;
import core.sys.posix.unistd : write;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import std.stdio : File;

package(daemon):

enum OBSERVE_FRAME_LIMIT = 2 * 1024 * 1024;
enum OBSERVE_QUEUE_LIMIT = 64;

struct FrameHeader
{
    string id;
    bool idComplete;
    bool hasMethod;
}

FrameHeader scanHeader(const(char)[] data)
{
    FrameHeader ret;
    int depth;
    bool inString;
    bool escaped;
    string pendingKey;
    char[] token;
    foreach (i, value; data)
    {
        if (inString)
        {
            if (escaped)
            {
                escaped = false;
                token ~= value;
            }
            else if (value == '\\')
                escaped = true;
            else if (value == '"')
            {
                inString = false;
                if (depth == 1)
                {
                    size_t next = i + 1;
                    while (next < data.length && (data[next] == ' ' || data[next] == '\t'))
                        next++;

                    if (next < data.length && data[next] == ':')
                    {
                        pendingKey = token.idup;
                        if (pendingKey == "method")
                            ret.hasMethod = true;
                    }
                    else
                    {
                        if (pendingKey == "id")
                        {
                            ret.id = token.idup;
                            ret.idComplete = true;
                        }

                        pendingKey = null;
                    }
                }

                token = null;
            }
            else if (depth <= 1)
                token ~= value;

            continue;
        }

        switch (value)
        {
        case '"':
            inString = true;
            token = null;
            break;
        case '{':
        case '[':
            depth++;
            break;
        case '}':
        case ']':
            if (depth > 0)
                depth--;
            break;
        default:
            break;
        }
    }

    return ret;
}

bool writeBounded(int fd, const(ubyte)[] bytes, shared(bool)* aborted)
{
    size_t offset;
    while (offset < bytes.length)
    {
        if (aborted !is null && atomicLoad(*aborted))
            return false;

        pollfd watch = pollfd(fd, POLLOUT);
        int ready = poll(&watch, 1, 100);
        if (ready < 0)
        {
            if (errno == EINTR)
                continue;
            return false;
        }
        if (ready == 0)
            continue;

        immutable count = write(fd, bytes.ptr + offset, bytes.length - offset);
        if (count < 0)
        {
            if (errno == EINTR)
                continue;
            return false;
        }
        if (count == 0)
            return false;

        offset += count;
    }

    return true;
}

struct FrameTap
{
    string frame;
    bool skip;

    void feed(FrameQueue queue, bool clientToAgent, ubyte[] chunk)
    {
        foreach (value; chunk)
        {
            if (value == '\n')
            {
                if (skip)
                {
                    skip = false;
                    frame = null;
                }
                else if (frame.length)
                {
                    queue.push(clientToAgent, frame);
                    frame = null;
                }
                else
                    queue.push(clientToAgent, "");

                continue;
            }

            if (!skip)
            {
                frame ~= cast(char)value;
                if (frame.length >= OBSERVE_FRAME_LIMIT)
                {
                    skip = true;
                    frame = null;
                }
            }
        }
    }
}

final class RelayIO
{
    File toChild;
    File fromChild;
    File input;
    File output;
}

class FrameQueue
{
private:
    Mutex mutex;
    Condition updated;
    bool[] directions;
    string[] frames;
    bool finished;

public:
    this()
    {
        mutex = new Mutex();
        updated = new Condition(mutex);
    }

    void push(bool clientToAgent, string frame)
    {
        synchronized (mutex)
        {
            if (frames.length >= OBSERVE_QUEUE_LIMIT)
                return;

            directions ~= clientToAgent;
            frames ~= frame;
            updated.notify();
        }
    }

    void finish()
    {
        synchronized (mutex)
        {
            finished = true;
            updated.notifyAll();
        }
    }

    bool pop(out bool clientToAgent, out string frame)
    {
        synchronized (mutex)
        {
            while (!frames.length && !finished)
                updated.wait();

            if (!frames.length)
                return false;

            clientToAgent = directions[0];
            frame = frames[0];
            directions = directions[1..$];
            frames = frames[1..$];
            return true;
        }
    }
}
