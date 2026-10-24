module tests.worker;

import daemon.exception : InvalidInputException;
import daemon.worker : WorkerWake;
import tests.common : waitUntil;

import unit_threaded : Name, should;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.array : split;
import std.conv : to;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption, SocketOptionLevel, SocketType;
import std.string : indexOf, strip, toLower;

@Name("Worker wake coalesces queued notices and closes permanently")
unittest
{
    Responder responder = new Responder([], "fixture-token");
    scope(exit)
        responder.close();
    WorkerWake wake = new WorkerWake(responder.port.to!string, "fixture-token");
    scope(exit)
        wake.stop();

    wake.notify();
    wake.notify();
    wake.notify();
    wake.start();
    waitUntil(delegate bool() { return responder.requestCount == 1; });
    wake.start();
    Thread.sleep(200.msecs);
    responder.requestCount.should == 1;
    responder.allValid.should == true;

    wake.stop();
    wake.stop();
    wake.notify();
    bool rejected;
    try
        wake.start();
    catch (InvalidInputException)
        rejected = true;
    rejected.should == true;
    Thread.sleep(200.msecs);
    responder.requestCount.should == 1;
}

@Name("Worker wake stopped before start can never notify")
unittest
{
    Responder responder = new Responder([], "fixture-token");
    scope(exit)
        responder.close();
    WorkerWake wake = new WorkerWake(responder.port.to!string, "fixture-token");
    scope(exit)
        wake.stop();

    wake.stop();
    wake.notify();
    bool rejected;
    try
        wake.start();
    catch (InvalidInputException)
        rejected = true;
    rejected.should == true;
    Thread.sleep(200.msecs);
    responder.requestCount.should == 0;
}

@Name("Worker wake retries one failed refresh inside bounded deadlines")
unittest
{
    Responder responder = new Responder([500], "fixture-token");
    scope(exit)
        responder.close();
    WorkerWake wake = new WorkerWake(responder.port.to!string, "fixture-token");
    scope(exit)
        wake.stop();

    wake.start();
    wake.notify();
    waitUntil(delegate bool() { return responder.requestCount >= 2; });
    wake.stop();
    responder.allValid.should == true;
}

/// Fixture-owned loopback responder that counts and validates wake requests.
private class Responder
{
    private Socket listener;
    private Thread thread;
    private Mutex mutex;
    private int[] statuses;
    private string capability;
    private shared(bool) running = true;
    private size_t requests;
    private bool valid = true;
    const ushort port;

    this(int[] statuses, string capability)
    {
        this.statuses = statuses;
        this.capability = capability;
        mutex = new Mutex();
        listener = new Socket(AddressFamily.INET, SocketType.STREAM);
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(4);
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 100.msecs);
        port = (cast(InternetAddress)listener.localAddress).port;
        thread = new Thread({
            serve();
        });
        thread.start();
    }

    size_t requestCount()
    {
        synchronized (mutex)
            return requests;
    }

    bool allValid()
    {
        synchronized (mutex)
            return valid;
    }

    void close()
    {
        atomicStore(running, false);
        listener.close();
        thread.join();
    }

    private void serve()
    {
        while (atomicLoad(running))
        {
            Socket client;
            try
                client = listener.accept();
            catch (Exception)
                continue;
            scope(exit)
                client.close();
            client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 2.seconds);
            client.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, 2.seconds);
            try
                handle(client);
            catch (Exception)
            {
                synchronized (mutex)
                    valid = false;
            }
        }
    }

    private void handle(Socket client)
    {
        char[2048] chunk;
        char[] data;
        while (data.indexOf("\r\n\r\n") < 0 && data.length <= 8 * 1024)
        {
            immutable ptrdiff_t got = client.receive(chunk);
            if (got <= 0)
                throw new Exception("Truncated wake request");
            data ~= chunk[0 .. got];
        }

        immutable ptrdiff_t splitAt = data.indexOf("\r\n\r\n");
        if (splitAt < 0)
            throw new Exception("Oversized wake request");

        string[] lines = data[0 .. splitAt].idup.split("\r\n");
        string request = lines[0];
        size_t contentLength;
        bool token;
        foreach (line; lines[1 .. $])
        {
            immutable ptrdiff_t colon = line.indexOf(':');
            if (colon <= 0)
                continue;
            string name = line[0 .. colon].strip.toLower;
            string value = line[colon + 1 .. $].strip;
            if (name == "content-length")
                contentLength = value.to!size_t;
            if (name == "x-autonom-client" && value == capability)
                token = true;
        }
        if (contentLength > 8 * 1024)
            throw new Exception("Oversized wake request");

        string bodyText = data[splitAt + 4 .. $].idup;
        while (bodyText.length < contentLength)
        {
            immutable ptrdiff_t got = client.receive(chunk);
            if (got <= 0)
                throw new Exception("Truncated wake request");
            bodyText ~= chunk[0 .. got];
        }

        bool ok = request == "POST /api/worker/refresh HTTP/1.1" && token && bodyText == "{}";
        int status;
        synchronized (mutex)
        {
            status = statuses.length ? statuses[0] : 200;
            if (statuses.length)
                statuses = statuses[1 .. $];
            ++requests;
            valid = valid && ok;
        }

        string reply = "HTTP/1.1 "~status.to!string~" Response\r\n"~
            "content-length: 0\r\nconnection: close\r\n\r\n";
        const(char)[] remaining = reply;
        while (remaining.length)
        {
            immutable ptrdiff_t sent = client.send(remaining);
            if (sent <= 0)
                throw new Exception("Failed to answer the wake request");
            remaining = remaining[sent .. $];
        }
    }
}
