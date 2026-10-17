module tests.interop.acp.common;

import daemon.interop.acp;
import daemon.interop.mcp : MCP_SERVER_NAME, injectCoord;
import tests.common;
import unit_threaded : Name, Serial, should, shouldThrow;

import core.sync.mutex : Mutex;
import core.sys.posix.unistd : read;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.algorithm : canFind, endsWith;
import std.array : join, replicate, split;
import std.file;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process;
import std.socket;
import std.stdio : File;

public:

string agentPath()
    => buildPath(getcwd(), "source", "tests", "fakeagent.py");

string[] agentCommand()
    => ["python3", agentPath(), "acp"];

string[string] agentEnvironment(Fixture fixture)
    => [
        "AUTONOM_FAKE_DIR": fixture.root,
        "AUTONOM_FAKE_LOCKDIR": fixture.config.sessionLockDir,
        "PATH": environment.get("PATH", "/usr/bin:/bin")
    ];

class LineCollector
{
    Mutex mutex;
    string[] lines;
    string partial;
    bool done;

    this()
    {
        mutex = new Mutex;
    }

    void pump(File source)
    {
        try
        {
            ubyte[8192] buffer;
            for (;;)
            {
                immutable count = read(source.fileno, buffer.ptr, buffer.length);
                if (count <= 0)
                    break;

                synchronized (mutex)
                {
                    foreach (value; buffer[0..count])
                    {
                        if (value == '\n')
                        {
                            lines ~= partial.idup;
                            partial = null;
                        }
                        else if (value != '\r')
                            partial ~= cast(char)value;
                    }
                }
            }
        }
        catch (Exception)
        {
        }

        synchronized (mutex)
            done = true;
    }

    string[] snapshot()
    {
        synchronized (mutex)
            return lines.dup;
    }
}

public:

