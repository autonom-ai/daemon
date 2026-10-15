module daemon.relay;

import daemon.config;
import daemon.interop.acp;

import core.atomic : atomicOp;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.sys.posix.sys.time;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.conv : octal, to;
import std.file : FileException, exists, isDir, isSymlink, mkdirRecurse, read, remove, setAttributes;
import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.path : buildPath, dirName;
import std.process : environment;
import std.socket : AddressFamily, Socket, SocketOption, SocketOptionLevel, SocketType,
    UnixAddress;
import std.stdio : stderr;
import std.string : startsWith, strip;
import std.uuid : randomUUID;

private:

enum HEARTBEAT = 10.seconds;
enum CONTROL_LIMIT = 64 * 1024;
enum PENDING_LIMIT = 64;
enum REPLY_LIMIT = 128;
enum DELIVERY_LIMIT = 64;
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

class ControlConnection
{
    Socket socket;
    string requestId;
    string wireId;
    string sessionId;
    string method;

    this(Socket socket)
    {
        this.socket = socket;
    }
}

struct Delivery
{
    Socket socket;
    string line;
}

class RelayControl : RelayInjection
{
private:
    Mutex mutex;
    Condition updated;
    string[] pending;
    ControlConnection[string] replies;
    Delivery[] outbox;
    bool closed;
    Thread delivery;
    RelayAgent agent;

    void deliver(ControlConnection conn, JSONValue reply)
    {
        JSONValue wire = JSONValue([
            "jsonrpc": JSONValue("2.0"),
            "id": conn.requestId.length ? JSONValue(conn.requestId) : JSONValue(null)
        ]);
        wire.object["result"] = reply;
        deliverRaw(conn.socket, wire.toString());
    }

    void deliverError(ControlConnection conn, int code, string message)
    {
        JSONValue wire = JSONValue([
            "jsonrpc": JSONValue("2.0"),
            "id": conn.requestId.length ? JSONValue(conn.requestId) : JSONValue(null),
            "error": JSONValue([
                "code": JSONValue(code),
                "message": JSONValue(message)
            ])
        ]);
        deliverRaw(conn.socket, wire.toString());
    }

    void deliverRaw(Socket socket, string line)
    {
        bool queued;
        synchronized (mutex)
        {
            if (outbox.length < DELIVERY_LIMIT)
            {
                outbox ~= Delivery(socket, line);
                queued = true;
                updated.notify();
            }
        }
        if (!queued)
            try
                socket.close();
            catch (Exception)
            {
            }
    }

    ControlConnection claim(const(char)[] prefix)
    {
        FrameHeader head = scanHeader(prefix);
        if (!head.idComplete || head.hasMethod || !head.id.length)
            return null;

        synchronized (mutex)
        {
            ControlConnection* found = head.id in replies;
            if (found is null)
                return null;

            ControlConnection ret = *found;
            replies.remove(head.id);
            return ret;
        }
    }

    void deliveryLoop()
    {
        for (;;)
        {
            Delivery item;
            synchronized (mutex)
            {
                while (!outbox.length && !closed)
                    updated.wait();
                if (!outbox.length)
                    return;

                item = outbox[0];
                outbox = outbox[1..$];
            }

            try
                writeSocket(item.socket, item.line);
            catch (Exception)
            {
            }
            try
                item.socket.close();
            catch (Exception)
            {
            }
        }
    }

public:
    this()
    {
        mutex = new Mutex();
        updated = new Condition(mutex);
        delivery = new Thread(&deliveryLoop);
        delivery.start();
    }

    bool take(out string frame)
    {
        synchronized (mutex)
        {
            if (!pending.length)
                return false;

            frame = pending[0];
            pending = pending[1..$];
            return true;
        }
    }

    bool consume(const(char)[] prefix)
    {
        FrameHeader head = scanHeader(prefix);
        if (!head.idComplete || head.hasMethod || !head.id.length)
            return false;

        synchronized (mutex)
            return (head.id in replies) !is null;
    }

    void consumed(string frame)
    {
        ControlConnection target = claim(frame);
        if (target is null)
            return;

        agent.promptDone(target.method, target.sessionId);
        JSONValue message;
        try
            message = parseJSON(frame);
        catch (Exception)
        {
        }

        if (message.type == JSONType.object && "error" in message.object && !message["error"].isNull)
        {
            JSONValue wire = JSONValue([
                "jsonrpc": JSONValue("2.0"),
                "id": JSONValue(target.requestId),
                "error": message["error"]
            ]);
            deliverRaw(target.socket, wire.toString());
            return;
        }

        deliver(target, message.type == JSONType.object && "result" in message.object ?
            message["result"] : JSONValue(null));
    }

    void dropped(const(char)[] prefix)
    {
        ControlConnection target = claim(prefix);
        if (target is null)
            return;

        agent.promptDone(target.method, target.sessionId);
        deliverError(target, -32603, "Agent reply exceeded the relay control limit");
    }

    bool enqueue(string frame)
    {
        synchronized (mutex)
        {
            if (pending.length >= PENDING_LIMIT)
                return false;

            pending ~= frame;
            return true;
        }
    }

    bool reserve(string wireId, ControlConnection connection)
    {
        synchronized (mutex)
        {
            if (replies.length >= REPLY_LIMIT)
                return false;

            replies[wireId] = connection;
            return true;
        }
    }

    void release(string wireId)
    {
        synchronized (mutex)
            replies.remove(wireId);
    }

    void close()
    {
        synchronized (mutex)
        {
            closed = true;
            updated.notifyAll();
        }
        if (delivery !is null)
        {
            delivery.join();
            delivery = null;
        }
        synchronized (mutex)
        {
            foreach (conn; replies)
            {
                try
                    conn.socket.close();
                catch (Exception)
                {
                }
            }
            replies = null;
        }
    }

    bool isClosed()
    {
        synchronized (mutex)
            return closed;
    }
}

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
                if (count <= 0)
                    return;

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

bool tokenEqual(string left, string right) nothrow
{
    if (left.length != right.length || !left.length)
        return false;

    uint difference;
    foreach (i, character; left)
        difference |= character ^ right[i];

    return difference == 0;
}

void writeSocket(Socket socket, string line)
{
    ubyte[] bytes = cast(ubyte[])(line~"\n");
    size_t offset;
    while (offset < bytes.length)
    {
        immutable sent = socket.send(bytes[offset..$]);
        if (sent <= 0)
            return;

        offset += sent;
    }
}

void writeResult(Socket socket, string id, JSONValue result)
{
    writeSocket(socket, JSONValue([
        "jsonrpc": JSONValue("2.0"),
        "id": id.length ? JSONValue(id) : JSONValue(null),
        "result": result
    ]).toString());
}

void writeError(Socket socket, string id, int code, string message)
{
    writeSocket(socket, JSONValue([
        "jsonrpc": JSONValue("2.0"),
        "id": id.length ? JSONValue(id) : JSONValue(null),
        "error": JSONValue([
            "code": JSONValue(code),
            "message": JSONValue(message)
        ])
    ]).toString());
}

int main(string[] args)
{
    string devin = environment.get("AUTONOM_DEVIN", "devin");
    string configPath;
    for (size_t i = 1; i < args.length; i++)
    {
        if (args[i] == "--devin" && i + 1 < args.length)
            devin = args[++i];
        else if (args[i] == "--config" && i + 1 < args.length)
            configPath = args[++i];
    }

    RelayAgent agent;
    if (configPath.length)
    {
        try
        {
            Config config = new Config(configPath);
            string connection = randomUUID().toString();
            agent = new RelayAgent(
                strip((cast(char[])read(buildPath(config.dataDir, "client.token"))).idup),
                environment.get("AUTONOM_PORT", "8080"),
                connection,
                buildPath(config.dataDir, "acp", connection~".sock")
            );
        }
        catch (Exception error)
        {
            stderr.writeln("autonom-acp: control disabled: ", error.msg);
            agent = new RelayAgent("", environment.get("AUTONOM_PORT", "8080"), null, null);
        }
    }
    else
        agent = new RelayAgent("", environment.get("AUTONOM_PORT", "8080"), null, null);

    agent.begin();
    string[string] child = environment.toAA;
    foreach (name; child.keys)
    {
        if (name.startsWith("AUTONOM_CLIENT_") || name.startsWith("AUTONOM_RUN_"))
            child.remove(name);
    }

    int status = runRelay(
        [devin, "acp"],
        child,
        null,
        (bool clientToAgent, string frame) { agent.frame(clientToAgent, frame); },
        agent.injection
    );
    agent.close();
    return status;
}
