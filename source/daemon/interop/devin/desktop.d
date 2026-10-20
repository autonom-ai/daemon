module daemon.interop.devin.desktop;

import daemon.interop.acp;
import daemon.interop.mcp : mcpServerName, injectCoord;

import core.atomic : atomicLoad, atomicStore;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.conv : octal;
import std.file : exists, isDir, isSymlink, mkdirRecurse, remove, setAttributes;
import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.path : dirName;
import std.socket;
import std.uuid : randomUUID;

/// Desktop's stdio peer and the authenticated control socket share one ACP connection.
class Desktop
{
private:
    struct Instance
    {
        string directory;
        string capability;
    }

    AcpClient agent;
    string token;
    string port;
    string id;
    string socketPath;
    Mutex mutex;
    Mutex httpMutex;
    Condition changed;
    bool dirty = true;
    Instance[string] sessions;
    Socket listener;
    Thread serving;
    Thread heartbeat;
    Thread[] clients;
    shared bool halted;

    void post(string path, JSONValue body)
    {
        if (!token.length)
            return;
        HTTP request = HTTP("http://127.0.0.1:"~port~path);
        request.proxy = "";
        request.connectTimeout = 1.seconds;
        request.operationTimeout = 2.seconds;
        request.addRequestHeader("x-autonom-client", token);
        request.setPostData(body.toString(), "application/json");
        request.onReceive = (ubyte[] bytes) => bytes.length;
        request.perform();
        if (request.statusLine.code != 200)
            throw new Exception("Autonom rejected the ACP connection update");
    }

    void observe(bool closed = false)
    {
        synchronized (httpMutex)
        {
            JSONValue listed = JSONValue.emptyArray;
            Instance[string] snapshot;
            synchronized (mutex)
                snapshot = sessions.dup;

            foreach (session, instance; snapshot)
            {
                // A surviving CLI retains this capability when the daemon restarts.
                if (!closed)
                {
                    post("/api/acp/admit", JSONValue([
                        "connection": JSONValue(id),
                        "session": JSONValue(session),
                        "token": JSONValue(instance.capability),
                        "directory": JSONValue(instance.directory)
                    ]));
                }

                listed.array ~= JSONValue([
                    "id": JSONValue(session),
                    "directory": JSONValue(instance.directory)
                ]);
            }
            post("/api/acp/observe", JSONValue([
                "connection": JSONValue(id),
                "sessions": listed,
                "closed": JSONValue(closed)
            ]));
        }
    }

    void queueObservation()
    {
        synchronized (mutex)
        {
            dirty = true;
            changed.notify();
        }
    }

    void outgoing(ref Frame frame)
    {
        string method = frame.method;
        if (method == "session/new" || method == "session/load")
        {
            JSONValue params = frame.value["params"];
            if ("_meta" !in params.object || params["_meta"].type != JSONType.object)
                params["_meta"] = JSONValue.emptyObject;
            params["_meta"]["autonom/connector"] = JSONValue("autonom");
            if (token.length)
            {
                string issued;
                foreach (_; 0..2)
                {
                    foreach (character; randomUUID().toString())
                    {
                        if (character != '-')
                            issued ~= character;
                    }
                }
                params = injectCoord(params, port, issued);
            }
            frame.value["params"] = params;
        }
    }

    void beforeReply(ref Frame frame, Frame sent)
    {
        if ((sent.method != "session/new" && sent.method != "session/load") || "error" in frame.value.object)
            return;
        JSONValue params = sent.value["params"];
        JSONValue result = frame.value["result"];
        string session = "sessionId" in result.object ? result["sessionId"].str : params["sessionId"].str;
        string directory = params["cwd"].str;
        string issued;
        if (token.length)
        {
            foreach (server; params["mcpServers"].array)
            {
                if (server["name"].str != mcpServerName)
                    continue;
                foreach (entry; server["env"].array)
                {
                    if (entry["name"].str == "AUTONOM_MCP_TOKEN")
                        issued = entry["value"].str;
                }
            }
            synchronized (httpMutex)
            {
                post("/api/acp/admit", JSONValue([
                    "connection": JSONValue(id),
                    "session": JSONValue(session),
                    "token": JSONValue(issued),
                    "directory": JSONValue(directory)
                ]));
            }
        }
        synchronized (mutex)
            sessions[session.idup] = Instance(directory.idup, issued.idup);

        queueObservation();
    }

    static void send(Socket socket, JSONValue frame)
    {
        string line = frame.toString()~"\n";
        size_t offset;
        while (offset < line.length)
        {
            ptrdiff_t count = socket.send(cast(ubyte[])line[offset..$]);
            if (count <= 0)
                throw new Exception("ACP control write failed");
            offset += count;
        }
    }

    JSONValue control(JSONValue request)
    {
        string provided = request["token"].str;
        uint difference = cast(uint)(provided.length ^ token.length);
        if (provided.length == token.length)
        {
            foreach (i, character; provided)
                difference |= character ^ token[i];
        }
        if (!token.length || difference)
            throw new AcpException(-32001, "Unauthorized");
        string method = request["method"].str;
        JSONValue params = request["params"];
        string session = params["sessionId"].str;
        synchronized (mutex)
        {
            if (session !in sessions)
                throw new AcpException(-32002, "Unknown session on this connection");
        }
        switch (method)
        {
        case "session/cancel":
            agent.notify(method, params);
            return JSONValue.emptyObject;
        case "session/prompt":
        case "session/set_config_option":
            return agent.request(method, params, 30 * 60.seconds);
        case "autonom/activity":
            return JSONValue(cast(string)agent.activity(session));
        case "autonom/deliver":
            return agent.await(agent.deliver(params), 30 * 60.seconds);
        case "autonom/permissions":
            return agent.permissions(session, "id" in params.object ? params["id"].integer : 0);
        case "autonom/permission":
            agent.decide(session, params["id"].integer,
                "optionId" in params.object && params["optionId"].type == JSONType.string ? params["optionId"].str : null);
            return JSONValue.emptyObject;
        default:
            throw new AcpException(-32601, "Unsupported ACP control method");
        }
    }

    void serve(Socket socket)
    {
        scope(exit)
            socket.close();
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 5.seconds);
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, 2.seconds);
        JSONValue identity = JSONValue(null);
        try
        {
            string line;
            ubyte[4096] buffer;
            while (line.length <= frameLimit)
            {
                ptrdiff_t count = socket.receive(buffer);
                if (count <= 0)
                    return;
                foreach (val; buffer[0..count])
                {
                    if (val == '\n')
                    {
                        JSONValue request = parseJSON(line);
                        identity = request["id"];
                        JSONValue result = control(request);
                        send(socket, JSONValue(["jsonrpc": JSONValue("2.0"), "id": identity, "result": result]));
                        return;
                    }
                    line ~= cast(char)val;
                    if (line.length > frameLimit)
                        throw new AcpException(-32600, "ACP control request is too large");
                }
            }
        }
        catch (Exception error)
        {
            AcpException protocol = cast(AcpException)error;
            try
            {
                send(socket, JSONValue([
                    "jsonrpc": JSONValue("2.0"),
                    "id": identity,
                    "error": JSONValue([
                        "code": JSONValue(protocol is null ? -32603 : protocol.code),
                        "message": JSONValue(protocol is null ? "ACP control request failed" : protocol.msg)
                    ])
                ]));
            }
            catch (Exception)
            { }
        }
    }

    void listen()
    {
        while (!atomicLoad(halted))
        {
            foreach (i; 0..clients.length)
            {
                if (!clients[i].isRunning)
                {
                    clients[i].join();
                    clients = clients[0..i]~clients[i + 1..$];
                    break;
                }
            }
            try
            {
                Socket socket = listener.accept();
                if (clients.length >= 16)
                    socket.close();
                else
                {
                    Thread client = new Thread({
                        serve(socket);
                    });
                    clients ~= client;
                    client.start();
                }
            }
            catch (SocketOSException)
                Thread.sleep(20.msecs);
        }
    }

public:
    this(AcpClient agent, string token, string port, string id, string socketPath)
    {
        this.agent = agent;
        this.token = token;
        this.port = port;
        this.id = id;
        this.socketPath = socketPath;
        mutex = new Mutex();
        httpMutex = new Mutex();
        changed = new Condition(mutex);
        agent.outgoing = &outgoing;
        agent.beforeReply = &beforeReply;
        if (!token.length)
            return;
        string directory = dirName(socketPath);
        if (exists(directory) && (!isDir(directory) || isSymlink(directory)))
            throw new Exception("ACP control directory must be a regular directory");
        mkdirRecurse(directory);
        setAttributes(directory, octal!"700");
        if (exists(socketPath))
            throw new Exception("ACP control path already exists");
        listener = new Socket(AddressFamily.UNIX, SocketType.STREAM);
        listener.bind(new UnixAddress(socketPath));
        setAttributes(socketPath, octal!"600");
        listener.listen(8);
        listener.blocking = false;
        serving = new Thread(&listen);
        serving.start();
        heartbeat = new Thread({
            while (!atomicLoad(halted))
            {
                synchronized (mutex)
                {
                    if (!dirty && !atomicLoad(halted))
                        changed.wait(10.seconds);

                    dirty = false;
                }

                if (atomicLoad(halted))
                    return;

                try
                    observe();
                catch (Exception)
                { }
            }
        });
        heartbeat.start();
    }

    void close()
    {
        atomicStore(halted, true);
        synchronized (mutex)
            changed.notify();

        if (serving !is null)
            serving.join();
        if (heartbeat !is null)
            heartbeat.join();
        foreach (client; clients)
            client.join();
        if (listener !is null)
            listener.close();
        try
            observe(true);
        catch (Exception)
        { }
        if (socketPath.length && exists(socketPath))
            remove(socketPath);
    }
}
