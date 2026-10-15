module daemon.relay.agent;

import daemon.interop.acp : ACP_INJECT_PREFIX;
import daemon.relay.control;

import core.atomic : atomicOp;
import core.stdc.errno : errno, EINTR;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.conv : octal, to;
import std.file : exists, isDir, isSymlink, mkdirRecurse, remove, setAttributes;
import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.path : dirName;
import std.socket : AddressFamily, Socket, SocketOption, SocketOptionLevel, SocketType,
    UnixAddress;
import std.uuid : randomUUID;

private:

enum HEARTBEAT = 10.seconds;
enum CONTROL_LIMIT = 64 * 1024;
enum SERVE_LIMIT = 32;
enum INFLIGHT_LIMIT = 256;
enum string[] CONTROL_METHODS = [
    "session/prompt",
    "session/cancel",
    "session/set_config_option"
];

struct ObservedSession
{
    string id;
    string directory;
    size_t active;
}

bool tokenEqual(string left, string right) nothrow
{
    if (left.length != right.length || !left.length)
        return false;

    uint difference;
    foreach (i, character; left)
        difference |= character ^ right[i];

    return difference == 0;
}

Socket openListener(string socketPath)
{
    string directory = dirName(socketPath);
    if (exists(directory) && (!isDir(directory) || isSymlink(directory)))
        throw new Exception("Relay control directory must not be a symlink");
    if (!exists(directory))
        mkdirRecurse(directory);

    setAttributes(directory, octal!"700");
    if (exists(socketPath))
        throw new Exception("Relay control socket path already exists");

    Socket ret = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    ret.bind(new UnixAddress(socketPath));
    setAttributes(socketPath, octal!"600");
    ret.listen(8);
    return ret;
}

public:

class RelayAgent
{
private:
    struct Tracked
    {
        string method;
        string sessionId;
        string directory;
    }

    Mutex mutex;
    string connection;
    string token;
    string port;
    Tracked[string] inflight;
    ObservedSession[string] sessions;
    shared int serving;
    shared bool halted;
    RelayControl control;
    Socket listener;
    Thread heartbeat;
    Thread controlThread;
    Mutex wakeMutex;
    Condition woken;
    string socketPath;

    static string key(JSONValue id)
    {
        if (id.type == JSONType.string)
            return "s:"~id.str;
        if (id.type == JSONType.integer)
            return "i:"~id.integer.to!string;
        if (id.type == JSONType.uinteger)
            return "u:"~id.uinteger.to!string;

        return null;
    }

    void post(bool closed)
    {
        if (!token.length)
            return;

        JSONValue[] listed;
        synchronized (mutex)
        {
            foreach (entry; sessions)
            {
                listed ~= JSONValue([
                    "id": JSONValue(entry.id),
                    "directory": JSONValue(entry.directory),
                    "active": JSONValue(entry.active != 0)
                ]);
            }
        }

        JSONValue body = JSONValue([
            "connection": JSONValue(connection),
            "sessions": JSONValue(listed),
            "closed": JSONValue(closed)
        ]);
        try
        {
            HTTP request = HTTP("http://127.0.0.1:"~port~"/api/acp/observe");
            request.proxy = "";
            request.connectTimeout = 1.seconds;
            request.operationTimeout = 2.seconds;
            request.addRequestHeader("x-autonom-client", token);
            request.setPostData(body.toString(), "application/json");
            request.onReceive = (ubyte[] data) => data.length;
            request.perform();
        }
        catch (Exception)
        {
        }
    }

    void heartbeatLoop()
    {
        for (;;)
        {
            synchronized (wakeMutex)
            {
                if (!halted)
                    woken.wait(HEARTBEAT);
            }

            if (halted)
                break;

            post(false);
        }
    }

    void poke()
    {
        synchronized (wakeMutex)
            woken.notify();
    }

    void controlLoop()
    {
        while (!control.isClosed)
        {
            Socket connection;
            try
                connection = listener.accept();
            catch (Exception)
            {
                Thread.sleep(50.msecs);
                continue;
            }

            if (atomicOp!"+="(serving, 1) > SERVE_LIMIT)
            {
                atomicOp!"-="(serving, 1);
                try
                    connection.close();
                catch (Exception)
                {
                }
                continue;
            }

            serveAsync(connection);
        }
    }

    void serveAsync(Socket socket)
    {
        (new Thread({
            scope(exit)
                atomicOp!"-="(serving, 1);
            serve(socket);
        })).start();
    }

    void serve(Socket socket)
    {
        try
        {
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 30.seconds);
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, 10.seconds);
        }
        catch (Exception)
        {
        }

        ControlConnection conn = new ControlConnection(socket);
        string line;
        try
        {
            ubyte[8192] buffer;
            while (line.length < CONTROL_LIMIT)
            {
                immutable count = socket.receive(buffer);
                if (count == 0)
                    return;
                if (count == Socket.ERROR)
                {
                    if (errno == EINTR)
                        continue;

                    return;
                }

                foreach (byte value; buffer[0..count])
                {
                    if (value == '\n')
                    {
                        dispatch(conn, line);
                        return;
                    }

                    line ~= cast(char)value;
                }
            }
        }
        catch (Exception)
        {
        }

        try
            socket.close();
        catch (Exception)
        {
        }
    }

    void dispatch(ControlConnection conn, string line)
    {
        JSONValue request;
        try
            request = parseJSON(line);
        catch (Exception)
        {
            writeError(conn.socket, null, -32700, "Parse error");
            return;
        }

        if (request.type != JSONType.object || "token" !in request.object ||
            request["token"].type != JSONType.string || "id" !in request.object ||
            request["id"].type != JSONType.string || "method" !in request.object ||
            request["method"].type != JSONType.string || "params" !in request.object)
        {
            writeError(conn.socket, null, -32600, "Invalid request");
            return;
        }

        if (!tokenEqual(request["token"].str, token))
        {
            writeError(conn.socket, request["id"].str, -32001, "Unauthorized");
            return;
        }

        bool allowed;
        foreach (method; CONTROL_METHODS)
            allowed = allowed || request["method"].str == method;
        if (!allowed)
        {
            writeError(conn.socket, request["id"].str, -32601, "Method not found");
            return;
        }

        string session;
        if (request["params"].type == JSONType.object && "sessionId" in request["params"].object &&
            request["params"]["sessionId"].type == JSONType.string)
            session = request["params"]["sessionId"].str;

        synchronized (mutex)
        {
            if (!session.length || session !in sessions)
            {
                writeError(conn.socket, request["id"].str, -32002, "Unknown session on this connection");
                return;
            }
        }

        conn.requestId = request["id"].str.idup;
        conn.sessionId = session.idup;
        conn.method = request["method"].str.idup;
        if (conn.method == "session/cancel")
        {
            if (!control.enqueue(JSONValue([
                "jsonrpc": JSONValue("2.0"),
                "method": JSONValue("session/cancel"),
                "params": request["params"]
            ]).toString()))
            {
                writeError(conn.socket, conn.requestId, -32603, "Relay control queue is full");
                return;
            }

            writeResult(conn.socket, conn.requestId, JSONValue(cast(JSONValue[string])null));
            return;
        }

        string wireId;
        for (;;)
        {
            wireId = ACP_INJECT_PREFIX~randomUUID().toString();
            synchronized (mutex)
            {
                if (("s:"~wireId) !in inflight)
                    break;
            }
        }

        synchronized (mutex)
        {
            if (conn.method == "session/prompt" && session in sessions)
                sessions[session].active++;
        }
        if (!control.reserve(wireId, conn))
        {
            synchronized (mutex)
            {
                if (conn.method == "session/prompt" && session in sessions && sessions[session].active)
                    sessions[session].active--;
            }
            writeError(conn.socket, conn.requestId, -32603, "Relay control queue is full");
            return;
        }

        conn.wireId = wireId;
        if (!control.enqueue(JSONValue([
            "jsonrpc": JSONValue("2.0"),
            "id": JSONValue(wireId),
            "method": JSONValue(conn.method),
            "params": request["params"]
        ]).toString()))
        {
            control.release(wireId);
            synchronized (mutex)
            {
                if (conn.method == "session/prompt" && session in sessions && sessions[session].active)
                    sessions[session].active--;
            }
            writeError(conn.socket, conn.requestId, -32603, "Relay control queue is full");
            return;
        }

        poke();
    }

public:
    this(string token, string port, string connection, string socketPath)
    {
        mutex = new Mutex();
        wakeMutex = new Mutex();
        woken = new Condition(wakeMutex);
        this.token = token;
        this.port = port;
        this.connection = connection;
        this.socketPath = socketPath;
        if (socketPath.length)
        {
            control = new RelayControl();
            control.agent = this;
            listener = openListener(socketPath);
            listener.blocking = false;
        }
    }

    bool hasControl()
        => control !is null;

    RelayControl injection()
        => control;

    void begin()
    {
        heartbeat = new Thread(&heartbeatLoop);
        heartbeat.start();
        if (listener !is null)
        {
            controlThread = new Thread(&controlLoop);
            controlThread.start();
        }

        post(false);
    }

    void frame(bool clientToAgent, string data)
    {
        JSONValue message;
        try
            message = parseJSON(data);
        catch (Exception)
            return;

        if (message.type != JSONType.object)
            return;

        bool request = ("method" in message.object) !is null;
        string idKey = "id" in message.object ? key(message["id"]) : null;
        if (clientToAgent)
        {
            if (!request || !idKey.length)
                return;

            string method = message["method"].type == JSONType.string ? message["method"].str : null;
            string session;
            string directory;
            if ("params" in message.object && message["params"].type == JSONType.object)
            {
                JSONValue params = message["params"];
                if ("sessionId" in params.object && params["sessionId"].type == JSONType.string)
                    session = params["sessionId"].str;
                if ("cwd" in params.object && params["cwd"].type == JSONType.string)
                    directory = params["cwd"].str;
            }

            synchronized (mutex)
            {
                if (inflight.length >= INFLIGHT_LIMIT)
                    return;

                inflight[idKey] = Tracked(method, session, directory);
                if (method == "session/prompt" && session in sessions)
                    sessions[session].active++;
            }
            if (method == "session/prompt" || method == "session/new" || method == "session/load")
                poke();

            return;
        }

        if (request)
            return;
        if (!idKey.length)
            return;

        synchronized (mutex)
        {
            Tracked* found = idKey in inflight;
            if (found is null)
                return;

            Tracked tracked = *found;
            inflight.remove(idKey);
            bool outcome = "result" in message.object && !message["result"].isNull;
            if (tracked.method == "session/prompt" && tracked.sessionId in sessions)
            {
                ObservedSession* entry = tracked.sessionId in sessions;
                if (entry.active)
                    entry.active--;
            }
            if ((tracked.method == "session/new" || tracked.method == "session/load") &&
                outcome && message["result"].type == JSONType.object)
            {
                string id = "sessionId" in message["result"].object &&
                    message["result"]["sessionId"].type == JSONType.string ?
                    message["result"]["sessionId"].str : tracked.sessionId;
                if (id.length)
                    sessions[id.idup] = ObservedSession(id.idup, tracked.directory, 0);
            }
            if (tracked.method == "session/delete" && outcome && tracked.sessionId.length)
                sessions.remove(tracked.sessionId);
        }
        poke();
    }

    void promptDone(string method, string sessionId)
    {
        if (method != "session/prompt")
            return;

        synchronized (mutex)
        {
            ObservedSession* entry = sessionId in sessions;
            if (entry !is null && entry.active)
                entry.active--;
        }
        poke();
    }

    void close()
    {
        post(true);
        halted = true;
        synchronized (wakeMutex)
            woken.notifyAll();
        if (control !is null)
            control.close();
        if (listener !is null)
            try
                listener.close();
            catch (Exception)
            {
            }
        if (socketPath.length && exists(socketPath))
            try
                remove(socketPath);
            catch (Exception)
            {
            }
        if (heartbeat !is null)
        {
            heartbeat.join();
            heartbeat = null;
        }
        if (controlThread !is null)
        {
            controlThread.join();
            controlThread = null;
        }
    }
}
