module daemon.interop.acp.client;

import daemon.interop.acp.frames;
import daemon.interop.acp.permissions;
import daemon.interop.acp.routing;
import daemon.interop.process;

import core.stdc.errno : errno, EINTR;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.sys.posix.poll : pollFd = poll, pollfd, POLLIN, POLLOUT;
import core.sys.posix.sys.types : ssize_t;
import core.sys.posix.unistd : read, write;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.json : JSONValue;
import std.process : Config, Pid, ProcessPipes, Redirect, pipeProcess, tryWait;
import std.stdio : File;

class AcpException : Exception
{
    const int code;

    this(int code, string message, string file = __FILE__, size_t line = __LINE__)
    {
        this.code = code;
        super(message, file, line);
    }
}

package(daemon.interop.acp) class Response
{
    Frame sent;
    JSONValue originalId;
    bool peer;
    bool done;
    JSONValue result;
    int errorCode;
    string error;
}

package(daemon.interop.acp) struct Incoming
{
    Frame frame;
    MonoTime deadline;
    size_t bytes;
}

/// One child stream, its RPC correlation, and pending backend requests.
class AcpClient
{
package(daemon.interop.acp):
    enum cancelMethod = "$/cancel_request";

    Pid process;
    File toAgent;
    File fromAgent;
    File errorsPipe;
    File peerOutput;
    Thread reader;
    Thread errors;
    Mutex writeMutex;
    Mutex peerMutex;
    Mutex stateMutex;
    Condition updated;
    Response[long] requests;
    Incoming[long] incoming;
    long nextId = 1;
    size_t incomingBytes;
    bool terminated;
    bool closing;
    int _exitStatus = int.min;
    string failure;

public:
    Duration permissionTimeout = 240.seconds;
    void delegate(JSONValue message) notification;
    JSONValue delegate(JSONValue request) agentRequest;
    void delegate(ref Frame frame) outgoing;
    void delegate(ref Frame frame, Frame request) beforeReply;

    this(string[] command, string[string] environment, string cwd = null, File errorLog = File.init)
    {
        writeMutex = new Mutex();
        peerMutex = new Mutex();
        stateMutex = new Mutex();
        updated = new Condition(stateMutex);
        Config options = Config.newEnv;
        options.preExecFunction = &createProcessGroup;
        ProcessPipes pipes = pipeProcess(command, Redirect.stdin | Redirect.stdout | Redirect.stderr,
            environment, options, cwd);
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
            ssize_t count;
            while ((count = read(errorsFd, buffer.ptr, buffer.length)) > 0)
            {
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
        return this.submit(Frame(JSONValue([
            "jsonrpc": JSONValue("2.0"),
            "id": JSONValue(null),
            "method": JSONValue(method),
            "params": params
        ])), false);
    }

    void notify(string method, JSONValue params = JSONValue.emptyObject)
    {
        if (method == "session/cancel")
            this.cancelPermissions(params["sessionId"].str);

        writeFrame(toAgent, writeMutex, Frame(JSONValue([
            "jsonrpc": JSONValue("2.0"),
            "method": JSONValue(method),
            "params": params
        ])));
    }

    JSONValue await(long id, Duration timeout = Duration.max)
    {
        MonoTime deadline = timeout == Duration.max ? MonoTime.max : MonoTime.currTime + timeout;
        while (MonoTime.currTime < deadline)
        {
            this.expire();
            synchronized (stateMutex)
            {
                Response* response = id in requests;
                if (response is null)
                    throw new AcpException(-32000, "Unknown ACP request");
                if (response.done)
                {
                    Response result = *response;
                    requests.remove(id);
                    if (result.error.length)
                        throw new AcpException(result.errorCode, result.error);
                    return result.result;
                }
                if (MonoTime.currTime >= deadline)
                {
                    requests.remove(id);
                    throw new AcpException(-32000, "ACP request timed out");
                }
                updated.wait(100.msecs);
            }
        }
        synchronized (stateMutex)
            requests.remove(id);
        throw new AcpException(-32000, "ACP request timed out");
    }

    JSONValue request(string method, JSONValue params = JSONValue.emptyObject, Duration timeout = Duration.max)
        => await(send(method, params), timeout);

    bool poll(long id, out JSONValue result, out int code, out string message)
    {
        this.expire();
        synchronized (stateMutex)
        {
            Response* found = id in requests;
            if (found is null || !found.done)
                return false;
            result = found.result;
            code = found.errorCode;
            message = found.error;
            requests.remove(id);
            return true;
        }
    }

    int relay(File input, File output)
    {
        peerOutput = output;
        bool invalid;
        try
        {
            FrameReader frames;
            ubyte[8192] buffer;
            while (!disconnected)
            {
                this.expire();
                pollfd watch = pollfd(input.fileno, POLLIN);
                int ready = pollFd(&watch, 1, 100);
                if (ready < 0 && errno == EINTR || ready == 0)
                    continue;
                if (ready < 0)
                    break;
                ssize_t count = read(input.fileno, buffer.ptr, buffer.length);
                if (count <= 0)
                    break;
                frames.feed(buffer[0..count], (Frame frame) {
                    this.receivePeer(frame);
                });
            }
            frames.finish();
        }
        catch (Exception error)
        {
            invalid = true;
            failed(error.msg);
        }
        synchronized (stateMutex)
            invalid = invalid || (failure.length && failure != "Agent disconnected");
        close();
        return invalid ? 1 : _exitStatus;
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
        { }
        typeof(tryWait(Pid.init)) result = tryWait(process);
        if (!result.terminated)
        {
            MonoTime deadline = MonoTime.currTime + grace;
            while (!(result = tryWait(process)).terminated && MonoTime.currTime < deadline)
                Thread.sleep(10.msecs);
            if (!result.terminated)
            {
                _exitStatus = terminate(process, grace);
                result.terminated = true;
                result.status = _exitStatus;
            }
        }
        _exitStatus = result.terminated ? result.status : -1;
        process = null;
        synchronized (stateMutex)
            closing = true;
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
        fromAgent.close();
        errorsPipe.close();
        failed("ACP connection closed");
    }

package(daemon.interop.acp):
    void writeFrame(File file, Mutex mutex, Frame frame)
    {
        string line = frame.encode();
        MonoTime deadline = MonoTime.currTime + 30.seconds;
        synchronized (mutex)
        {
            size_t offset;
            while (offset < line.length)
            {
                synchronized (stateMutex)
                {
                    if (closing)
                        throw new AcpException(-32000, "ACP connection is closed");
                }
                if (MonoTime.currTime >= deadline)
                    throw new AcpException(-32000, "ACP write timed out");
                pollfd watch = pollfd(file.fileno, POLLOUT);
                int ready = pollFd(&watch, 1, 100);
                if (ready < 0 && errno == EINTR || ready == 0)
                    continue;
                if (ready < 0)
                    throw new AcpException(-32000, "ACP write failed");
                // A small write after POLLOUT cannot fill an empty pipe indefinitely.
                size_t count = line.length - offset > 4096 ? 4096 : line.length - offset;
                ssize_t sent = write(file.fileno, line.ptr + offset, count);
                if (sent < 0 && errno == EINTR)
                    continue;
                if (sent <= 0)
                    throw new AcpException(-32000, "ACP stream closed during write");
                offset += sent;
            }
        }
    }

    void answer(JSONValue id, JSONValue result)
    {
        return writeFrame(toAgent, writeMutex, Frame(JSONValue([
            "jsonrpc": JSONValue("2.0"),
            "id": id,
            "result": result
        ])));
    }

    void answerError(JSONValue id, int code, string message)
    {
        return writeFrame(toAgent, writeMutex, Frame(JSONValue([
            "jsonrpc": JSONValue("2.0"),
            "id": id,
            "error": JSONValue(["code": JSONValue(code),
            "message": JSONValue(message)])
        ])));
    }

    void failed(string message)
    {
        synchronized (stateMutex)
        {
            terminated = true;
            failure = message.idup;
            incoming = null;
            incomingBytes = 0;
            foreach (response; requests)
            {
                if (response.done)
                    continue;

                response.done = true;
                response.errorCode = -32000;
                response.error = failure;
            }
            updated.notifyAll();
        }
    }

    void readLoop()
    {
        try
        {
            FrameReader frames;
            ubyte[8192] buffer;
            bool receiving = true;
            while (receiving)
            {
                ssize_t count = read(fromAgent.fileno, buffer.ptr, buffer.length);
                if (count < 0 && errno == EINTR)
                    continue;
                receiving = count > 0;
                if (receiving)
                {
                    frames.feed(buffer[0..count], (Frame frame) {
                        this.dispatch(frame);
                    });
                }
            }
            frames.finish();
            failed("Agent disconnected");
        }
        catch (Exception error)
            failed(error.msg);
    }
}
