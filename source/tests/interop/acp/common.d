module tests.interop.acp.common;

import tests.common;

import core.sync.mutex : Mutex;
import core.sys.posix.sys.types : ssize_t;
import core.sys.posix.unistd : read;
import std.file;
import std.path : buildPath;
import std.process;
import std.socket;
import std.stdio : File;

string agentPath()
    => buildPath(getcwd(), "source", "tests", "fakeagent.py");

string[] agentCommand()
    => ["python3", agentPath(), "acp"];

string[string] agentEnvironment(Fixture fixture)
{
    return [
        "AUTONOM_FAKE_DIR": fixture.root,
        "AUTONOM_FAKE_LOCKDIR": fixture.config.sessionLockDir,
        "PATH": environment.get("PATH", "/usr/bin:/bin")
    ];
}

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
            ssize_t count;
            while ((count = read(source.fileno, buffer.ptr, buffer.length)) > 0)
            {
                synchronized (mutex)
                {
                    foreach (val; buffer[0..count])
                    {
                        if (val == '\n')
                        {
                            lines ~= partial.idup;
                            partial = null;
                        }
                        else if (val != '\r')
                            partial ~= cast(char)val;
                    }
                }
            }
        }
        catch (Exception)
        { }

        synchronized (mutex)
            done = true;
    }

    string[] snapshot()
    {
        synchronized (mutex)
            return lines.dup;
    }
}
