module daemon.relay.control;

import daemon.interop.acp : FrameHeader, RelayInjection, scanHeader;
import daemon.relay.agent;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.json : JSONType, JSONValue, parseJSON;
import std.socket : Socket;

private:

enum PENDING_LIMIT = 64;
enum REPLY_LIMIT = 128;
enum DELIVERY_LIMIT = 64;

struct Delivery
{
    Socket socket;
    string line;
}

public:

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
    package(daemon.relay) RelayAgent agent;

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
