/// Typed bounded handoff between call monitor threads and the owning worker.
module daemon.interop.completion;

import daemon.exception : InvalidInputException;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.process : thisProcessID;
import std.uuid : UUID;

/// Maximum notices the worker reconciles from the handoff in one pass.
enum completionBatchLimit = 8;

/// One posted completion; the execution id is owned by the posting side.
struct CompletionNotice
{
    string executionId;
    ulong generation;
}

/// One drained batch plus reconciliation flags for the worker.
struct CompletionBatch
{
    CompletionNotice[] notices;
    bool rescan;
    bool more;
}

/// Bounded ring of typed completion notices; Call state stays authoritative.
class CompletionHandoff
{
private:
    enum size_t maximumIdLength = 36;

    void delegate() wake;
    Mutex mutex;
    Thread creator;
    typeof(thisProcessID) creatorPid;
    CompletionNotice[] ring;
    size_t head;
    size_t count;
    ulong generation;
    bool stopped;
    bool rescan;

    void requireWorker(string operation) const
    {
        if (Thread.getThis() !is creator || thisProcessID != creatorPid)
            throw new InvalidInputException("CompletionHandoff." ~ operation ~
                " must run on the creating worker");
    }

    static bool validId(const(char)[] id)
    {
        if (!id.length || id.length > maximumIdLength)
            return false;
        try
        {
            UUID(id);
            return true;
        }
        catch (Exception)
            return false;
    }

    void clearLocked()
    {
        foreach (ref entry; ring)
            entry = CompletionNotice.init;
        head = 0;
        count = 0;
        rescan = false;
    }

    void signalWake()
    {
        if (wake !is null)
            wake();
    }

public:
    /// Bind the handoff to the creating worker thread and process.
    this(void delegate() wake = null, size_t capacity = 64)
    {
        if (capacity == 0)
            throw new InvalidInputException("Completion handoff requires a positive capacity");

        this.wake = wake;
        mutex = new Mutex();
        creator = Thread.getThis();
        creatorPid = thisProcessID;
        ring = new CompletionNotice[capacity];
        generation = 1;
    }

    /// Own an execution id for a later post; valid only on the creating worker.
    CompletionNotice capture(const(char)[] id)
    {
        requireWorker("capture");
        if (!validId(id))
            throw new InvalidInputException("Invalid execution ID");

        CompletionNotice ret;
        ret.executionId = id.idup;
        synchronized (mutex)
        {
            if (stopped)
                throw new InvalidInputException("Completion handoff is closed");
            ret.generation = generation;
        }
        return ret;
    }

    /// Post a captured notice from any thread; returns false when rejected or full.
    bool post(CompletionNotice notice)
    {
        bool accepted;
        bool signal;
        synchronized (mutex)
        {
            if (!stopped && notice.generation == generation && validId(notice.executionId))
            {
                signal = true;
                if (count < ring.length)
                {
                    ring[(head + count) % ring.length] =
                        CompletionNotice(notice.executionId.idup, notice.generation);
                    ++count;
                    accepted = true;
                }
                else
                    rescan = true;
            }
        }
        if (signal)
            signalWake();
        return accepted;
    }

    /// Remove at most limit notices; only the creating worker may drain.
    CompletionBatch drain(size_t limit = completionBatchLimit)
    {
        requireWorker("drain");
        if (limit == 0)
            throw new InvalidInputException("Completion drain requires a positive limit");

        CompletionBatch ret;
        synchronized (mutex)
        {
            immutable size_t taken = limit < count ? limit : count;
            ret.notices = new CompletionNotice[taken];
            foreach (i; 0 .. taken)
            {
                ret.notices[i] = ring[head];
                ring[head] = CompletionNotice.init;
                head = head + 1 == ring.length ? 0 : head + 1;
            }
            count -= taken;
            ret.rescan = rescan;
            ret.more = count > 0;
            rescan = false;
        }
        return ret;
    }

    /// Arm a full reconciliation scan and signal the worker wake; worker-only.
    void requestRescan()
    {
        requireWorker("requestRescan");
        synchronized (mutex)
        {
            if (stopped)
                return;
            rescan = true;
        }
        signalWake();
    }

    /// Rotate the generation so previously captured notices are rejected; stays open.
    void invalidate()
    {
        requireWorker("invalidate");
        synchronized (mutex)
        {
            if (stopped)
                throw new InvalidInputException("Completion handoff is closed");
            if (generation == ulong.max)
                throw new InvalidInputException("Completion generation exhausted");
            ++generation;
            clearLocked();
        }
    }

    /// Reject future posts and drop pending notices; idempotent, never reopens.
    void close()
    {
        requireWorker("close");
        synchronized (mutex)
        {
            stopped = true;
            clearLocked();
        }
    }

    /// Current notice generation for worker-side reconciliation checks.
    ulong currentGeneration()
    {
        requireWorker("currentGeneration");
        synchronized (mutex)
            return generation;
    }
}
