/// Coalesced transport-to-worker notification without off-thread domain access.
module daemon.worker;

import daemon.exception : InvalidInputException;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs, seconds;
import std.net.curl : HTTP;

/// Own a bounded one-bit wake request; only the HTTP worker applies domain transitions.
class WorkerWake
{
private:
    const string port;
    const string capability;
    Mutex mutex;
    Condition ready;
    Thread thread;
    bool pending;
    bool stopping;

public:
    this(string port, string capability)
    {
        this.port = port.idup;
        this.capability = capability.idup;
        mutex = new Mutex();
        ready = new Condition(mutex);
    }

    /// Start the notifier once; a closed wake can never restart.
    void start()
    {
        if (thread !is null)
            return;

        synchronized (mutex)
        {
            if (stopping)
                throw new InvalidInputException("Worker wake transport is closed");
        }
        scope(failure)
            stop();
        Thread started = new Thread({
            run();
        });
        started.start();
        thread = started;
    }

    /// Coalesce completion notices without waiting for the worker or an HTTP response.
    void notify()
    {
        synchronized (mutex)
        {
            if (stopping)
                return;

            pending = true;
            ready.notify();
        }
    }

    /// Reject new notices and join the notifier, bounded by its transport timeout.
    void stop()
    {
        synchronized (mutex)
        {
            stopping = true;
            pending = false;
            ready.notifyAll();
        }
        if (thread !is null)
        {
            thread.join();
            thread = null;
        }
    }

private:
    bool take()
    {
        synchronized (mutex)
        {
            while (!pending && !stopping)
                ready.wait();
            if (stopping)
                return false;

            pending = false;
            return true;
        }
    }

    bool poke()
    {
        try
        {
            HTTP client = HTTP("http://127.0.0.1:"~port~"/api/worker/refresh");
            client.proxy = "";
            client.connectTimeout = 1.seconds;
            client.operationTimeout = 2.seconds;
            client.addRequestHeader("x-autonom-client", capability);
            client.setPostData("{}", "application/json");
            client.perform();
            return client.statusLine.code == 200;
        }
        catch (Exception)
            return false;
    }

    void run()
    {
        while (take())
        {
            if (!poke())
            {
                Thread.sleep(100.msecs);
                notify();
            }
        }
    }
}
