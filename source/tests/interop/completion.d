module tests.interop.completion;

import daemon.interop.completion;

import unit_threaded : Name, should, shouldThrow;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : msecs, seconds, MonoTime;
import std.uuid : randomUUID;

@Name("Completion handoff drains posted notices in bounded FIFO order")
unittest
{
    CompletionHandoff handoff = new CompletionHandoff();
    string[] ids = [randomUUID().toString(), randomUUID().toString(), randomUUID().toString()];
    foreach (id; ids)
        handoff.post(handoff.capture(id)).should == true;

    CompletionBatch first = handoff.drain(2);
    first.notices.length.should == 2;
    first.notices[0].executionId.should == ids[0];
    first.notices[1].executionId.should == ids[1];
    first.more.should == true;
    first.rescan.should == false;

    CompletionBatch second = handoff.drain();
    second.notices.length.should == 1;
    second.notices[0].executionId.should == ids[2];
    second.more.should == false;
    second.rescan.should == false;

    handoff.drain().notices.length.should == 0;
}

@Name("Completion handoff rejects zero capacity and zero drain limits")
unittest
{
    new CompletionHandoff(null, 0).shouldThrow!Exception();
    CompletionHandoff handoff = new CompletionHandoff();
    handoff.drain(0).shouldThrow!Exception();
}

@Name("Capture and post own caller-provided id buffers")
unittest
{
    CompletionHandoff handoff = new CompletionHandoff();
    char[] raw = randomUUID().toString().dup;
    CompletionNotice captured = handoff.capture(cast(string)raw);
    string original = captured.executionId;
    raw[] = 'x';
    captured.executionId.should == original;

    char[] buffer = randomUUID().toString().dup;
    string posted = buffer.idup;
    CompletionNotice notice = CompletionNotice(cast(string)buffer, handoff.currentGeneration);
    handoff.post(notice).should == true;
    buffer[] = 'x';
    handoff.drain().notices[0].executionId.should == posted;
}

@Name("Overflow arms the rescan flag without dropping accepted notices")
unittest
{
    CompletionHandoff handoff = new CompletionHandoff(null, 2);
    string first = randomUUID().toString();
    string second = randomUUID().toString();
    handoff.post(handoff.capture(first)).should == true;
    handoff.post(handoff.capture(second)).should == true;
    handoff.post(handoff.capture(randomUUID().toString())).should == false;
    handoff.post(handoff.capture(randomUUID().toString())).should == false;

    CompletionBatch batch = handoff.drain();
    batch.rescan.should == true;
    batch.more.should == false;
    batch.notices.length.should == 2;
    batch.notices[0].executionId.should == first;
    batch.notices[1].executionId.should == second;

    CompletionBatch next = handoff.drain();
    next.notices.length.should == 0;
    next.rescan.should == false;
    next.more.should == false;
}

@Name("Invalidate rejects stale generations and keeps the handoff open")
unittest
{
    CompletionHandoff handoff = new CompletionHandoff(null, 2);
    CompletionNotice stale = handoff.capture(randomUUID().toString());
    handoff.invalidate();
    handoff.post(stale).should == false;
    handoff.drain().notices.length.should == 0;

    CompletionNotice fresh = handoff.capture(randomUUID().toString());
    handoff.post(fresh).should == true;
    CompletionBatch batch = handoff.drain();
    batch.notices.length.should == 1;
    batch.notices[0].executionId.should == fresh.executionId;
}

@Name("Close rejects late posts and stays idempotent")
unittest
{
    size_t wakes;
    CompletionHandoff handoff = new CompletionHandoff({ ++wakes; });
    CompletionNotice notice = handoff.capture(randomUUID().toString());
    handoff.post(notice).should == true;
    handoff.close();
    handoff.post(notice).should == false;
    throws({ handoff.capture(randomUUID().toString()); }).should == true;
    throws({ handoff.invalidate(); }).should == true;

    size_t before = wakes;
    handoff.requestRescan();
    wakes.should == before;

    handoff.close();
    handoff.post(notice).should == false;
    handoff.drain().notices.length.should == 0;
    handoff.currentGeneration.should == 1;
}

@Name("Worker-owned calls reject foreign threads while producers may post")
unittest
{
    CompletionHandoff handoff = new CompletionHandoff();
    CompletionNotice notice = handoff.capture(randomUUID().toString());

    bool posted;
    size_t rejected;
    Thread foreign = new Thread({
        foreach (operation; 0 .. 6)
        {
            try
            {
                switch (operation)
                {
                    case 0:
                        handoff.capture(randomUUID().toString());
                        break;
                    case 1:
                        handoff.drain();
                        break;
                    case 2:
                        handoff.invalidate();
                        break;
                    case 3:
                        handoff.close();
                        break;
                    case 4:
                        handoff.requestRescan();
                        break;
                    default:
                        handoff.currentGeneration;
                        break;
                }
            }
            catch (Exception)
                ++rejected;
        }
        posted = handoff.post(notice);
    });
    foreign.start();
    foreign.join();

    rejected.should == 6;
    posted.should == true;
    CompletionBatch batch = handoff.drain();
    batch.notices.length.should == 1;
    batch.notices[0].executionId.should == notice.executionId;
}

@Name("Wake callbacks run outside the queue lock")
unittest
{
    shared bool probeFinished;
    bool probePosted;
    bool probeReleased;
    Thread probe;
    CompletionHandoff handoff;
    CompletionNotice inner;
    handoff = new CompletionHandoff({
        if (probe !is null)
            return;

        probe = new Thread({
            probePosted = handoff.post(inner);
            atomicStore(probeFinished, true);
        });
        probe.start();
        // The probe can only finish its post if the wake ran outside the queue lock.
        MonoTime deadline = MonoTime.currTime + 2.seconds;
        while (!atomicLoad(probeFinished) && MonoTime.currTime < deadline)
            Thread.sleep(1.msecs);
        probeReleased = atomicLoad(probeFinished);
    }, 2);

    inner = handoff.capture(randomUUID().toString());
    CompletionNotice outer = handoff.capture(randomUUID().toString());
    handoff.post(outer).should == true;
    probe.join();
    probeReleased.should == true;
    probePosted.should == true;

    CompletionBatch batch = handoff.drain();
    batch.notices.length.should == 2;
    batch.notices[0].executionId.should == outer.executionId;
    batch.notices[1].executionId.should == inner.executionId;
}

private bool throws(scope void delegate() action)
{
    try
        action();
    catch (Exception)
        return true;
    return false;
}
