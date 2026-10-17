module daemon.interop.acp.client;

import daemon.interop.acp.frames;
import daemon.interop.process;

import core.stdc.errno : errno, EINTR;
import core.sys.posix.poll : pollFd = poll, pollfd, POLLIN, POLLOUT;
import core.sys.posix.unistd : read, write;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : to;
import std.json : JSONType, JSONValue;
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

private:

class Response
{
    Frame sent;
    JSONValue originalId;
    bool peer;
    bool done;
    JSONValue result;
    int errorCode;
    string error;
}

struct Incoming
{
    Frame frame;
    MonoTime deadline;
    size_t bytes;
}

public:

/// One child stream, its RPC correlation, and pending backend requests.
class AcpClient
{
private:
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

    long allocate()
    {
        if (nextId == long.max)
            throw new AcpException(-32000, "ACP request identity space exhausted");
        return nextId++;
    }

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
                auto sent = write(file.fileno, line.ptr + offset, count);
                if (sent < 0 && errno == EINTR)
                    continue;
                if (sent <= 0)
                    throw new AcpException(-32000, "ACP stream closed during write");
                offset += sent;
            }
        }
    }

    void answer(JSONValue id, JSONValue result)
        => writeFrame(toAgent, writeMutex, Frame(JSONValue([
            "jsonrpc": JSONValue("2.0"), "id": id, "result": result
        ])));

    void answerError(JSONValue id, int code, string message)
        => writeFrame(toAgent, writeMutex, Frame(JSONValue([
            "jsonrpc": JSONValue("2.0"), "id": id,
            "error": JSONValue(["code": JSONValue(code), "message": JSONValue(message)])
        ])));

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
            for (;;)
            {
                auto count = read(fromAgent.fileno, buffer.ptr, buffer.length);
                if (count < 0 && errno == EINTR)
                    continue;
                if (count <= 0)
                    break;
                frames.feed(buffer[0..count], &dispatch);
            }
            frames.finish();
            failed("Agent disconnected");
        }
        catch (Exception error)
            failed(error.msg);
    }

    void dispatch(Frame frame)
    {
        if (frame.request)
        {
            if (!frame.identified)
            {
                if (notification !is null)
                    notification(frame.value);
                if (peerOutput.isOpen)
                    writeFrame(peerOutput, peerMutex, frame);
                return;
            }
            if (frame.method == "session/request_permission" || peerOutput.isOpen)
            {
                long id;
                size_t bytes = frame.encode().length;
                synchronized (stateMutex)
                {
                    if (incoming.length >= 64 || bytes > FRAME_LIMIT - incomingBytes)
                        throw new AcpException(-32000, "Too many outstanding backend requests");
                    id = allocate();
                    incoming[id] = Incoming(frame, MonoTime.currTime + permissionTimeout, bytes);
                    incomingBytes += bytes;
                }
                if (peerOutput.isOpen)
                {
                    frame.value["id"] = JSONValue(id);
                    writeFrame(peerOutput, peerMutex, frame);
                }
                return;
            }
            try
            {
                if (agentRequest is null)
                    throw new AcpException(-32601, "Method not found");
                answer(frame.value["id"], agentRequest(frame.value));
            }
            catch (AcpException error)
                answerError(frame.value["id"], error.code, error.msg);
            catch (Exception error)
                answerError(frame.value["id"], -32603, error.msg);
            return;
        }

        JSONValue id = frame.value["id"];
        if (id.type != JSONType.integer && id.type != JSONType.uinteger)
            return;
        long identity = id.type == JSONType.integer ? id.integer : cast(long)id.uinteger;
        Response response;
        synchronized (stateMutex)
        {
            Response* found = identity in requests;
            if (found is null || found.done)
                return;
            response = *found;
        }
        // Required admission runs on this path before a successful reply is delivered.
        if (beforeReply !is null)
            beforeReply(frame, response.sent);
        if (response.peer)
        {
            synchronized (stateMutex)
                requests.remove(identity);
            frame.value["id"] = response.originalId;
            writeFrame(peerOutput, peerMutex, frame);
            return;
        }
        synchronized (stateMutex)
        {
            response.done = true;
            if ("error" in frame.value.object)
            {
                JSONValue error = frame.value["error"];
                response.errorCode = cast(int)error["code"].integer;
                response.error = error["message"].str;
            }
            else
                response.result = frame.value["result"];
            updated.notifyAll();
        }
    }

    long submit(Frame frame, bool peer)
    {
        Response response = new Response();
        long id;
        synchronized (stateMutex)
        {
            if (terminated || closing)
                throw new AcpException(-32000, "ACP connection is closed");
            if (requests.length >= REQUEST_LIMIT)
                throw new AcpException(-32000, "Too many outstanding ACP requests");
            id = allocate();
            response.peer = peer;
            response.originalId = frame.value["id"];
            frame.value["id"] = JSONValue(id);
            requests[id] = response;
        }
        try
        {
            if (outgoing !is null)
                outgoing(frame);
            response.sent = frame;
            writeFrame(toAgent, writeMutex, frame);
        }
        catch (Exception error)
        {
            synchronized (stateMutex)
                requests.remove(id);
            throw error;
        }
        return id;
    }

    void receivePeer(Frame frame)
    {
        if (frame.request)
        {
            if (frame.identified)
                submit(frame, true);
            else
                writeFrame(toAgent, writeMutex, frame);
            return;
        }
        JSONValue id = frame.value["id"];
        if (id.type != JSONType.integer)
            return;
        Incoming pending;
        synchronized (stateMutex)
        {
            Incoming* found = id.integer in incoming;
            if (found is null)
                return;
            pending = *found;
            if (pending.deadline <= MonoTime.currTime)
                return;
            if (pending.frame.method == "session/request_permission" && "result" in frame.value.object)
            {
                JSONValue result = frame.value["result"];
                JSONValue outcome = result["outcome"];
                string kind = outcome["outcome"].str;
                if (kind != "selected" && kind != "cancelled")
                    throw new AcpException(-32602, "Invalid native permission outcome");
                if (kind == "selected")
                {
                    bool offered;
                    foreach (option; pending.frame.value["params"]["options"].array)
                        offered = offered || option["optionId"].str == outcome["optionId"].str;
                    if (!offered)
                        throw new AcpException(-32602, "Native permission option was not offered");
                }
            }
            incomingBytes -= pending.bytes;
            incoming.remove(id.integer);
        }
        frame.value["id"] = pending.frame.value["id"];
        writeFrame(toAgent, writeMutex, frame);
    }

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
            for (;;)
            {
                auto count = read(errorsFd, buffer.ptr, buffer.length);
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
        => submit(Frame(JSONValue([
            "jsonrpc": JSONValue("2.0"), "id": JSONValue(null),
            "method": JSONValue(method), "params": params
        ])), false);

    void notify(string method, JSONValue params = JSONValue.emptyObject)
        => writeFrame(toAgent, writeMutex, Frame(JSONValue([
            "jsonrpc": JSONValue("2.0"), "method": JSONValue(method), "params": params
        ])));

    JSONValue await(long id, Duration timeout = Duration.max)
    {
        MonoTime deadline = timeout == Duration.max ? MonoTime.max : MonoTime.currTime + timeout;
        for (;;)
        {
            expire();
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
    }

    JSONValue request(string method, JSONValue params = JSONValue.emptyObject, Duration timeout = Duration.max)
        => await(send(method, params), timeout);

    bool poll(long id, out JSONValue result, out int code, out string message)
    {
        expire();
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

    JSONValue permissions(string session, long requestId = 0)
    {
        expire();
        JSONValue ret = JSONValue.emptyArray;
        synchronized (stateMutex)
        {
            foreach (id, pending; incoming)
            {
                if (pending.frame.method != "session/request_permission" || (requestId && id != requestId))
                    continue;
                JSONValue params = pending.frame.value["params"];
                if (params["sessionId"].str != session)
                    continue;
                JSONValue entry = JSONValue([
                    "id": JSONValue(id), "session": JSONValue(session),
                    "options": params["options"]
                ]);
                if (requestId)
                    entry["context"] = params;
                ret.array ~= entry;
            }
        }
        return ret;
    }

    void decide(string session, long id, string option = null)
    {
        Incoming pending;
        synchronized (stateMutex)
        {
            Incoming* found = id in incoming;
            if (found is null || found.deadline <= MonoTime.currTime ||
                found.frame.method != "session/request_permission" ||
                found.frame.value["params"]["sessionId"].str != session)
                throw new AcpException(-32002, "Permission request is no longer pending");
            pending = *found;
            if (option.length)
            {
                bool offered;
                foreach (entry; pending.frame.value["params"]["options"].array)
                    offered = offered || entry["optionId"].str == option;
                if (!offered)
                    throw new AcpException(-32602, "Permission option was not offered");
            }
            incomingBytes -= pending.bytes;
            incoming.remove(id);
        }
        JSONValue outcome = JSONValue(["outcome": JSONValue(option.length ? "selected" : "cancelled")]);
        if (option.length)
            outcome["optionId"] = JSONValue(option);
        answer(pending.frame.value["id"], JSONValue(["outcome": outcome]));
    }

    void expire()
    {
        Incoming[] expired;
        synchronized (stateMutex)
        {
            foreach (id; incoming.keys)
            {
                if (incoming[id].deadline <= MonoTime.currTime)
                {
                    expired ~= incoming[id];
                    incomingBytes -= incoming[id].bytes;
                    incoming.remove(id);
                }
            }
        }
        foreach (pending; expired)
        {
            if (pending.frame.method == "session/request_permission")
                answer(pending.frame.value["id"], JSONValue([
                    "outcome": JSONValue(["outcome": JSONValue("cancelled")])
                ]));
            else
                answerError(pending.frame.value["id"], -32000, "Client request timed out");
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
                expire();
                pollfd watch = pollfd(input.fileno, POLLIN);
                int ready = pollFd(&watch, 1, 100);
                if (ready < 0 && errno == EINTR || ready == 0)
                    continue;
                if (ready < 0)
                    break;
                auto count = read(input.fileno, buffer.ptr, buffer.length);
                if (count <= 0)
                    break;
                frames.feed(buffer[0..count], &receivePeer);
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
        catch (Exception) {}
        auto result = tryWait(process);
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
}
