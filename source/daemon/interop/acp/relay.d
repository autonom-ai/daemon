module daemon.interop.acp.relay;

import daemon.interop.acp.frames;
import daemon.interop.process;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.errno : errno, EINTR;
import core.sys.posix.poll : poll, pollfd, POLLIN;
import core.sys.posix.unistd : close, pipe, read, write;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.process : Config, Pid, ProcessPipes, Redirect, pipeProcess, tryWait;
import std.stdio : File, stdin, stdout;

public:

enum ACP_INJECT_PREFIX = "autonom:";

alias RelayObserver = void delegate(bool clientToAgent, string frame);

interface RelayInjection
{
    bool take(out string frame);
    bool consume(const(char)[] prefix);
    void consumed(string frame);
    void dropped(const(char)[] prefix);
}

int runRelay(
    string[] command,
    string[string] environment,
    string cwd = null,
    RelayObserver observer = null,
    RelayInjection injection = null,
    File input = stdin,
    File output = stdout
)
{
    Config options = Config.newEnv;
    options.preExecFunction = &createProcessGroup;
    ProcessPipes pipes = pipeProcess(
        command,
        Redirect.stdin | Redirect.stdout,
        environment,
        options,
        cwd
    );
    RelayIO io = new RelayIO();
    io.toChild = pipes.stdin;
    io.fromChild = pipes.stdout;
    io.input = input;
    io.output = output;
    int inputFd = io.input.fileno;
    int toChildFd = io.toChild.fileno;
    int fromChildFd = io.fromChild.fileno;
    int outputFd = io.output.fileno;
    Pid child = pipes.pid;

    FrameQueue observed = observer is null ? null : new FrameQueue();
    Thread observedThread;
    if (observed !is null)
    {
        observedThread = new Thread({
            bool direction;
            string frame;
            while (observed.pop(direction, frame))
            {
                try
                    observer(direction, frame);
                catch (Exception)
                {
                }
            }
        });
        observedThread.start();
    }

    int[2] wake;
    if (pipe(wake) != 0)
        wake[] = -1;

    shared bool drained;
    shared bool broken;
    shared bool aborted;
    FrameTap clientTap;
    FrameTap agentTap;

    enum DECIDING = 0;
    enum FORWARDING = 1;
    enum CONSUMING = 2;
    enum DISCARDING = 3;

    Thread agentToClient = new Thread({
        ubyte[8192] buffer;
        char[] head;
        char[] consumeHead;
        string consumed;
        int state = injection is null ? FORWARDING : DECIDING;
        shared(bool)* stopping = &aborted;
        MonoTime stopAt;
        for (;;)
        {
            if (stopping !is null && atomicLoad(*stopping))
            {
                stopping = null;
                stopAt = MonoTime.currTime + 2.seconds;
            }
            if (stopping is null && MonoTime.currTime >= stopAt)
                break;

            pollfd watch = pollfd(fromChildFd, POLLIN);
            int ready = poll(&watch, 1, stopping is null ? 0 : 100);
            if (ready == 0)
            {
                if (stopping is null)
                    break;
                continue;
            }
            if (ready < 0)
            {
                if (errno == EINTR)
                    continue;
                break;
            }
            if (!watch.revents)
                continue;

            immutable count = read(fromChildFd, buffer.ptr, buffer.length);
            if (count < 0)
            {
                if (errno == EINTR)
                    continue;
                break;
            }
            if (count == 0)
                break;

            size_t offset;
            while (offset < count)
            {
                size_t line = offset;
                while (line < count && buffer[line] != '\n')
                    line++;
                bool ended = line < count;
                ubyte[] segment = buffer[offset..line];
                offset = line + (ended ? 1 : 0);

                if (state == DISCARDING)
                {
                    if (ended)
                        state = DECIDING;
                    continue;
                }

                if (state == CONSUMING)
                {
                    bool finished = ended;
                    if (consumed.length + segment.length <= CONSUME_FRAME_LIMIT)
                        consumed ~= cast(char[])segment;
                    else
                    {
                        try
                            injection.dropped(consumeHead);
                        catch (Exception)
                        {
                        }
                        consumeHead = null;
                        consumed = null;
                        state = DISCARDING;
                        finished = false;
                    }
                    if (finished)
                    {
                        try
                            injection.consumed(consumed);
                        catch (Exception)
                        {
                        }
                        consumed = null;
                        consumeHead = null;
                        state = DECIDING;
                    }
                    continue;
                }

                if (state == DECIDING)
                {
                    size_t keep = 0;
                    if (head.length < CONSUME_PREFIX_LIMIT)
                    {
                        keep = segment.length > CONSUME_PREFIX_LIMIT - head.length ?
                            CONSUME_PREFIX_LIMIT - head.length : segment.length;
                        head ~= cast(char[])segment[0..keep];
                    }
                    if (!ended && head.length < CONSUME_PREFIX_LIMIT)
                        continue;

                    bool take = false;
                    if (injection !is null)
                    {
                        try
                            take = injection.consume(head);
                        catch (Exception)
                        {
                        }
                    }

                    ubyte[] rest = segment[keep..$];
                    if (take)
                    {
                        consumeHead = head;
                        head = null;
                        if (consumeHead.length + rest.length > CONSUME_FRAME_LIMIT)
                        {
                            try
                                injection.dropped(consumeHead);
                            catch (Exception)
                            {
                            }
                            consumeHead = null;
                            state = ended ? DECIDING : DISCARDING;
                        }
                        else
                        {
                            consumed = cast(string)consumeHead ~ cast(string)rest;
                            if (ended)
                            {
                                try
                                    injection.consumed(consumed);
                                catch (Exception)
                                {
                                }
                                consumed = null;
                                consumeHead = null;
                                state = DECIDING;
                            }
                            else
                                state = CONSUMING;
                        }
                        continue;
                    }

                    ubyte[] leading = cast(ubyte[])head;
                    head = null;
                    if (!writeBounded(outputFd, leading, stopping) ||
                        !writeBounded(outputFd, rest, stopping) ||
                        (ended && !writeBounded(outputFd, cast(ubyte[])"\n", stopping)))
                    {
                        atomicStore(broken, true);
                        break;
                    }
                    if (observed !is null)
                    {
                        agentTap.feed(observed, false, leading);
                        agentTap.feed(observed, false, rest);
                        if (ended)
                            agentTap.feed(observed, false, cast(ubyte[])"\n");
                    }
                    state = ended ? DECIDING : FORWARDING;
                    continue;
                }

                if (!writeBounded(outputFd, segment, stopping) ||
                    (ended && !writeBounded(outputFd, cast(ubyte[])"\n", stopping)))
                {
                    atomicStore(broken, true);
                    break;
                }
                if (observed !is null)
                    agentTap.feed(observed, false, buffer[offset - segment.length - (ended ? 1 : 0)..offset]);
                if (ended)
                    state = DECIDING;
            }
        }

        atomicStore(drained, true);
    });

    Thread clientToAgent = new Thread({
        ubyte[8192] buffer;
        bool boundary = true;
        for (;;)
        {
            if (atomicLoad(drained) || atomicLoad(broken) || atomicLoad(aborted))
                break;

            pollfd[2] fds = [pollfd(inputFd, POLLIN), pollfd(wake[0], POLLIN)];
            int ready = poll(fds.ptr, 2, 50);
            if (ready == 0)
            {
                if (boundary && injection !is null)
                    injectPending(injection, toChildFd, &aborted);

                continue;
            }
            if (ready < 0)
            {
                if (errno == EINTR)
                    continue;
                break;
            }
            if (fds[1].revents)
                break;
            if (!fds[0].revents)
                continue;

            immutable count = read(inputFd, buffer.ptr, buffer.length);
            if (count < 0)
            {
                if (errno == EINTR)
                    continue;
                break;
            }
            if (count == 0)
                break;

            if (!writeBounded(toChildFd, buffer[0..count], &aborted))
                break;

            if (observed !is null)
                clientTap.feed(observed, true, buffer[0..count]);

            boundary = buffer[count - 1] == '\n';
            if (boundary && injection !is null)
                injectPending(injection, toChildFd, &aborted);
        }

        io.toChild.close();
    });

    agentToClient.start();
    clientToAgent.start();

    typeof(tryWait(Pid.init)) result;
    MonoTime force;
    while (!(result = tryWait(child)).terminated)
    {
        if (atomicLoad(drained) || atomicLoad(broken))
        {
            if (force == MonoTime.init)
                force = MonoTime.currTime + 2.seconds;
            if (MonoTime.currTime >= force)
                break;
        }

        Thread.sleep(10.msecs);
    }

    int status = result.terminated ? result.status : terminate(child, 5.seconds);
    atomicStore(aborted, true);

    if (wake[1] >= 0)
    {
        ubyte signal = 1;
        write(wake[1], &signal, 1);
    }

    agentToClient.join();
    clientToAgent.join();
    if (wake[0] >= 0)
        close(wake[0]);
    if (wake[1] >= 0)
        close(wake[1]);
    try
        io.fromChild.close();
    catch (Exception)
    {
    }
    if (observed !is null)
    {
        observed.finish();
        observedThread.join();
    }

    try
        io.output.flush();
    catch (Exception)
    {
    }

    return status;
}

private:

enum CONSUME_PREFIX_LIMIT = 8 * 1024;
enum CONSUME_FRAME_LIMIT = 4 * 1024 * 1024;

void injectPending(RelayInjection injection, int toChildFd, shared(bool)* aborted)
{
    for (;;)
    {
        string frame;
        if (!injection.take(frame))
            break;
        if (!writeBounded(toChildFd, cast(ubyte[])(frame~"\n"), aborted))
            return;
    }
}
