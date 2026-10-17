module daemon.interop.process;

import core.stdc.errno : errno, ESRCH;
import core.sys.linux.sys.prctl : prctl, PR_SET_PDEATHSIG;
import core.sys.posix.signal : kill, SIGKILL, SIGTERM;
import core.sys.posix.unistd : setpgid;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs;
import std.exception : ErrnoException;
import std.process : Pid, tryWait, wait;

bool createProcessGroup() nothrow @nogc @trusted
{
    return setpgid(0, 0) == 0 && prctl(
        PR_SET_PDEATHSIG,
        SIGTERM,
        0,
        0,
        0
    ) == 0;
}

void signal(Pid process, int signal)
{
    if (process !is null && process.processID > 0)
    {
        if (kill(-process.processID, signal) != 0 && errno != ESRCH)
            throw new ErrnoException("Could not signal execution");
    }
}

int terminate(Pid process, Duration grace)
{
    typeof(tryWait(Pid.init)) result = tryWait(process);
    if (result.terminated)
        return result.status;

    signal(process, SIGTERM);
    MonoTime deadline = MonoTime.currTime + grace;
    while (!(result = tryWait(process)).terminated && MonoTime.currTime < deadline)
        Thread.sleep(10.msecs);

    if (!result.terminated)
    {
        signal(process, SIGKILL);
        result.status = wait(process);
        result.terminated = true;
    }

    return result.status;
}
