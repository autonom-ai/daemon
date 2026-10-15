module daemon.interop.acp.client;

import daemon.interop.process;

import core.stdc.errno : errno, EINTR;
import core.sys.posix.unistd : close, read, write;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.exception : ErrnoException;
import std.json : JSONType, JSONValue, parseJSON;
import std.process : Config, Pid, ProcessPipes, Redirect, pipeProcess, tryWait;
import std.stdio : File;

public:

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
