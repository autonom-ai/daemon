module daemon.interop.acp;

import daemon.interop.process;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.errno : errno, EINTR;
import core.sys.posix.poll : poll, pollfd, POLLIN, POLLOUT;
import core.sys.posix.unistd : close, pipe, read, write;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.exception : ErrnoException;
import std.json : JSONType, JSONValue, parseJSON;
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

class AcpException : Exception
{
    const int code;

    this(int code, string message, string file = __FILE__, size_t line = __LINE__)
    {
        this.code = code;
        super(message, file, line);
    }
}

final class AcpResponse
{
    bool done;
    JSONValue result;
    int errorCode;
    string errorMessage;
}

class AcpClient
{
private:
    Pid process;
    File toAgent;
    File fromAgent;
    File errorsPipe;
    Thread reader;
    Thread errors;
    Mutex writeMutex;
    Mutex stateMutex;
    Condition updated;
    AcpResponse[long] requests;
    long nextId;
    bool terminated;
    int _exitStatus = int.min;
    string failure;

    void sendLine(string line)
    {
        ubyte[] bytes = cast(ubyte[])(line~"\n");
        synchronized (writeMutex)
        {
            if (terminated)
                throw new AcpException(-32000, "Agent process is closed");

            writeFully(toAgent.fileno, bytes);
        }
    }

    void answer(JSONValue id, JSONValue result)
    {
        try
        {
            sendLine(JSONValue([
                "jsonrpc": JSONValue("2.0"),
                "id": id,
                "result": result
            ]).toString());
        }
        catch (Exception)
        {
        }
    }

    void answerError(JSONValue id, int code, string message)
    {
        try
        {
            sendLine(JSONValue([
                "jsonrpc": JSONValue("2.0"),
                "id": id,
                "error": JSONValue([
                    "code": JSONValue(code),
                    "message": JSONValue(message)
                ])
            ]).toString());
        }
        catch (Exception)
        {
        }
    }

    void readLoop()
    {
        string frame;
        ubyte[8192] buffer;
        for (;;)
        {
            immutable count = read(fromAgent.fileno, buffer.ptr, buffer.length);
            if (count < 0 && errno == EINTR)
                continue;
            if (count <= 0)
                break;

            foreach (byte value; buffer[0..count])
            {
                if (value == '\n')
                {
                    dispatch(frame);
                    frame = null;
                }
                else
                    frame ~= cast(char)value;
            }
        }
        if (frame.length)
            dispatch(frame);

        synchronized (stateMutex)
        {
            terminated = true;
            failure = "Agent disconnected";
            foreach (response; requests)
            {
                if (response.done)
                    continue;

                response.done = true;
                response.errorCode = -32000;
                response.errorMessage = failure;
            }

            updated.notifyAll();
        }
    }

    void dispatch(string frame)
    {
        while (frame.length && (frame[$-1] == '\r'))
            frame = frame[0..$-1];

        if (!frame.length)
            return;

        JSONValue message;
        try
            message = parseJSON(frame);
        catch (Exception)
            return;

        if (message.type != JSONType.object)
            return;

        if ("method" in message.object)
        {
            if ("id" in message.object)
            {
                JSONValue result;
                int code;
                string error;
                try
                {
                    if (agentRequest is null)
                        throw new AcpException(-32601, "Method not found");

                    result = agentRequest(message);
                }
                catch (AcpException exception)
                {
                    code = exception.code;
                    error = exception.msg;
                }
                catch (Exception exception)
                {
                    code = -32603;
                    error = exception.msg;
                }

                if (error.length)
                    answerError(message["id"], code, error);
                else
                    answer(message["id"], result);
            }
            else if (notification !is null)
            {
                try
                    notification(message);
                catch (Exception)
                {
                }
            }

            return;
        }

        if ("id" !in message.object)
            return;

        long id;
        JSONValue identity = message["id"];
        if (identity.type == JSONType.integer)
            id = identity.integer;
        else if (identity.type == JSONType.uinteger)
            id = cast(long)identity.uinteger;
        else
            return;

        synchronized (stateMutex)
        {
            AcpResponse* found = id in requests;
            if (found is null)
                return;

            found.done = true;
            if ("error" in message.object && !message["error"].isNull &&
                message["error"].type == JSONType.object)
            {
                JSONValue error = message["error"];
                found.errorCode = "code" in error.object && error["code"].type == JSONType.integer ?
                    cast(int)error["code"].integer : -32603;
                found.errorMessage = "message" in error.object && error["message"].type == JSONType.string ?
                    error["message"].str : "Agent request failed";
            }
            else
                found.result = "result" in message.object ? message["result"] : JSONValue(null);

            updated.notifyAll();
        }
    }

public:
    void delegate(JSONValue message) notification;
    JSONValue delegate(JSONValue request) agentRequest;

    this(
        string[] command,
        string[string] environment,
        string cwd = null,
        File errorLog = File.init
    )
    {
        writeMutex = new Mutex();
        stateMutex = new Mutex();
        updated = new Condition(stateMutex);
        Config options = Config.newEnv;
        options.preExecFunction = &createProcessGroup;
        ProcessPipes pipes = pipeProcess(
            command,
            Redirect.stdin | Redirect.stdout | Redirect.stderr,
            environment,
            options,
            cwd
        );
        process = pipes.pid;
        toAgent = pipes.stdin;
        fromAgent = pipes.stdout;
        errorsPipe = pipes.stderr;
        int errorsFd = errorsPipe.fileno;
        pipes.stdin.detach();
        pipes.stdout.detach();
        pipes.stderr.detach();
        File* target = new File();
        *target = errorLog;
        errors = new Thread({
            ubyte[4096] buffer;
            size_t written;
            for (;;)
            {
                immutable count = read(errorsFd, buffer.ptr, buffer.length);
                if (count <= 0)
                    break;
                if (target.isOpen && written < 1024 * 1024)
                {
                    size_t kept = count > 1024 * 1024 - written ? 1024 * 1024 - written : count;
                    target.rawWrite(buffer[0..kept]);
                    written += kept;
                }
            }
            if (target.isOpen)
                target.flush();
        });
        errors.start();
        reader = new Thread(&readLoop);
        reader.start();
    }

    long send(string method, JSONValue params = JSONValue.emptyObject)
    {
        AcpResponse response;
        long id;
        synchronized (stateMutex)
        {
            if (terminated)
                throw new AcpException(-32000, "Agent process is closed");

            id = nextId++;
            response = new AcpResponse();
            requests[id] = response;
        }

        try
        {
            sendLine(JSONValue([
                "jsonrpc": JSONValue("2.0"),
                "id": JSONValue(id),
                "method": JSONValue(method),
                "params": params
            ]).toString());
        }
        catch (Exception error)
        {
            synchronized (stateMutex)
            {
                requests.remove(id);
                response.done = true;
            }

            throw error;
        }

        return id;
    }

    void notify(string method, JSONValue params = JSONValue.emptyObject)
    {
        sendLine(JSONValue([
            "jsonrpc": JSONValue("2.0"),
            "method": JSONValue(method),
            "params": params
        ]).toString());
    }

    JSONValue await(long id, Duration timeout = Duration.max)
    {
        MonoTime deadline = timeout == Duration.max ? MonoTime.max : MonoTime.currTime + timeout;
        AcpResponse response;
        synchronized (stateMutex)
            response = requests[id];

        if (response is null)
            throw new AcpException(-32000, "Unknown agent request");

        for (;;)
        {
            synchronized (stateMutex)
            {
                if (response.done)
                {
                    requests.remove(id);
                    if (response.errorMessage.length)
                        throw new AcpException(response.errorCode, response.errorMessage);

                    return response.result;
                }

                Duration remaining = deadline - MonoTime.currTime;
                if (remaining <= Duration.zero)
                {
                    requests.remove(id);
                    throw new AcpException(-32000, "Agent request timed out");
                }

                updated.wait(remaining > 100.msecs ? 100.msecs : remaining);
            }
        }
    }

    JSONValue request(string method, JSONValue params = JSONValue.emptyObject, Duration timeout = Duration.max)
        => await(send(method, params), timeout);

    bool poll(long id, out JSONValue result, out int code, out string message)
    {
        synchronized (stateMutex)
        {
            AcpResponse* found = id in requests;
            if (found is null || !found.done)
                return false;

            result = found.result;
            code = found.errorCode;
            message = found.errorMessage;
            requests.remove(id);
            return true;
        }
    }

    bool disconnected()
    {
        synchronized (stateMutex)
            return terminated;
    }

    int exitStatus()
        => _exitStatus;

    void close(Duration grace = 5.seconds)
    {
        if (process is null)
            return;
        try
            toAgent.close();
        catch (Exception)
        {
        }

        typeof(tryWait(Pid.init)) result = tryWait(process);
        if (!result.terminated)
        {
            MonoTime deadline = MonoTime.currTime + grace;
            while (!(result = tryWait(process)).terminated && MonoTime.currTime < deadline)
                Thread.sleep(10.msecs);

            if (!result.terminated)
            {
                terminate(process, grace);
                result = tryWait(process);
            }
        }

        _exitStatus = result.terminated ? result.status : -1;
        process = null;
        if (reader !is null)
        {
            reader.join();
            reader = null;
        }
        if (errors !is null)
        {
            errors.join();
            errors = null;
        }

        try
            fromAgent.close();
        catch (Exception)
        {
        }
        try
            errorsPipe.close();
        catch (Exception)
        {
        }
    }
}

private:

enum OBSERVE_FRAME_LIMIT = 2 * 1024 * 1024;
enum OBSERVE_QUEUE_LIMIT = 64;
enum CONSUME_PREFIX_LIMIT = 8 * 1024;
enum CONSUME_FRAME_LIMIT = 4 * 1024 * 1024;

void writeFully(int fd, ubyte[] bytes)
{
    size_t offset;
    while (offset < bytes.length)
    {
        immutable count = write(fd, bytes.ptr + offset, bytes.length - offset);
        if (count < 0)
        {
            if (errno == EINTR)
                continue;

            throw new ErrnoException("Could not write relay frame");
        }
        if (count == 0)
            throw new Exception("Could not write relay frame");

        offset += count;
    }
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

package(daemon):

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

public:

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
        for (;;)
        {
            if (atomicLoad(aborted))
                break;

            pollfd watch = pollfd(fromChildFd, POLLIN);
            int ready = poll(&watch, 1, 100);
            if (ready == 0)
                continue;
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
                    if (!writeBounded(outputFd, leading, &aborted) ||
                        !writeBounded(outputFd, rest, &aborted) ||
                        (ended && !writeBounded(outputFd, cast(ubyte[])"\n", &aborted)))
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

                if (!writeBounded(outputFd, segment, &aborted) ||
                    (ended && !writeBounded(outputFd, cast(ubyte[])"\n", &aborted)))
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
