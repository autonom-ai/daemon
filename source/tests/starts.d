module tests.starts;

import daemon.agent : ProfileStore;
import daemon.agent.starts : ProfileStarts;
import daemon.exception : InvalidInputException;
import daemon.interop.call : Call, CallKind, CallStatus;
import tests.common : Fixture, installFake, waitUntil;

import unit_threaded : Name, should, shouldThrow;

import core.thread : Thread;
import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_UN;
import std.conv : to;
import std.file : exists, isSymlink, mkdirRecurse, readText, remove, symlink, write;
import std.path : buildPath;
import std.stdio : File;

private Call startCall(Fixture fixture, string name, string prompt, string sessionId)
{
    write(buildPath(fixture.root, "next-session-id"), sessionId);
    return fixture.starts.start(name, prompt, fixture.root);
}

private void releaseBarrier(Fixture fixture)
{
    write(buildPath(fixture.root, "release-completions"), "");
}

private void collectAndRefresh(Fixture fixture)
{
    fixture.bridge.collect();
    fixture.starts.refresh().should == false;
}

@Name("A pending profile start cannot displace a newer explicit binding")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    fixture.store.register("held", "session-a");
    Call pending = startCall(fixture, "held", "barrier", "pending-session");
    waitUntil(delegate bool() {
        return exists(buildPath(fixture.root, "barrier-pending-session"));
    });

    fixture.store.register("held", "session-c");
    releaseBarrier(fixture);
    pending.wait();
    pending.status.should == CallStatus.Succeeded;
    collectAndRefresh(fixture);
    fixture.store.get("held").session.id.should == "session-c";
}

@Name("An A-B-A explicit rebind rejects a stale start intent marker")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    fixture.store.register("held", "session-a");
    Call pending = startCall(fixture, "held", "barrier", "stale-session");
    waitUntil(delegate bool() {
        return exists(buildPath(fixture.root, "barrier-stale-session"));
    });

    fixture.store.register("held", "session-c");
    fixture.store.register("held", "session-a");
    releaseBarrier(fixture);
    pending.wait();
    pending.status.should == CallStatus.Succeeded;
    collectAndRefresh(fixture);
    fixture.store.get("held").session.id.should == "session-a";
}

@Name("A newer accepted start wins over a settled superseded intent")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    Call older = startCall(fixture, "held", "done", "older-session");
    older.wait();
    older.status.should == CallStatus.Succeeded;

    Call newer = startCall(fixture, "held", "done", "newer-session");
    newer.wait();
    newer.status.should == CallStatus.Succeeded;

    fixture.bridge.collect();
    fixture.starts.bind(older).should == false;
    fixture.starts.bind(newer).should == true;
    fixture.starts.refresh().should == false;
    fixture.store.get("held").session.id.should == "newer-session";
}

@Name("A rejected newer start restores the older settled intent")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    Call older = startCall(fixture, "held", "done", "older-session");
    older.wait();
    older.status.should == CallStatus.Succeeded;

    fixture.starts.start("held", "", fixture.root).shouldThrow!InvalidInputException();
    collectAndRefresh(fixture);
    fixture.store.get("held").session.id.should == "older-session";
}

@Name("Intent ownership, replacement stores, close, and foreign threads reject publication")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Fixture foreign = Fixture.create();
    scope(exit)
        foreign.close();
    installFake(fixture);

    Call owned = startCall(fixture, "held", "done", "owned-session");
    owned.wait();
    owned.status.should == CallStatus.Succeeded;
    fixture.bridge.collect();

    Call sameId = new Call(buildPath(foreign.root, "executions"),
        buildPath(foreign.root, "logs"), owned.id, CallKind.Start, fixture.root, "");
    fixture.starts.bind(sameId).should == false;

    ProfileStore replacement = new ProfileStore(fixture.config, fixture.bridge);
    ProfileStarts replacementStarts = new ProfileStarts(replacement, fixture.bridge);
    scope(exit)
        replacementStarts.close();
    replacementStarts.bind(owned).should == false;

    fixture.starts.close();
    fixture.starts.start("held", "done", fixture.root).shouldThrow!InvalidInputException();
    fixture.starts.bind(owned).should == false;
    fixture.starts.refresh().should == false;

    size_t rejected;
    Thread worker = new Thread({
        foreach (op; [
            { cast(void)fixture.starts.start("held", "done", fixture.root); },
            { cast(void)fixture.starts.bind(owned); },
            { cast(void)fixture.starts.refresh(); },
            { fixture.starts.close(); }
        ])
        {
            try
                op();
            catch (InvalidInputException)
                rejected++;
        }
    });
    worker.start();
    worker.join();
    rejected.should == 4;
}

@Name("An unchanged accepted start binds and a duplicate running start conflicts")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    Call accepted = startCall(fixture, "held", "barrier", "bound-session");
    waitUntil(delegate bool() {
        return exists(buildPath(fixture.root, "barrier-bound-session"));
    });
    fixture.starts.start("held", "done", fixture.root).shouldThrow!Exception();

    releaseBarrier(fixture);
    accepted.wait();
    accepted.status.should == CallStatus.Succeeded;
    collectAndRefresh(fixture);
    fixture.store.get("held").session.id.should == "bound-session";
}

@Name("A same-session resume invalidates a pending start snapshot")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    Call first = fixture.bridge.start("work", fixture.root);
    first.wait();
    first.status.should == CallStatus.Succeeded;
    fixture.bridge.collect();
    fixture.store.register("held", first.sessionId);

    Call pending = startCall(fixture, "held", "barrier", "pending-session");
    waitUntil(delegate bool() {
        return exists(buildPath(fixture.root, "barrier-pending-session"));
    });

    Call resumed = fixture.bridge.resume(first.sessionId, "done", fixture.root, null);
    resumed.wait();
    resumed.status.should == CallStatus.Succeeded;

    releaseBarrier(fixture);
    pending.wait();
    pending.status.should == CallStatus.Succeeded;
    collectAndRefresh(fixture);
    fixture.store.get("held").session.id.should == first.sessionId;
}

@Name("A registration conflict releases the intent permanently")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    fixture.store.register("held", "session-a");
    Call pending = startCall(fixture, "held", "done", "pending-session");
    pending.wait();
    pending.status.should == CallStatus.Succeeded;
    fixture.bridge.collect();
    pending.isCollected.should == true;

    mkdirRecurse(fixture.config.sessionLockDir);
    File lock = File(buildPath(fixture.config.sessionLockDir, "session-a.lock"), "w+");
    scope(exit)
    {
        if (lock.isOpen)
            lock.close();
    }
    flock(lock.fileno, LOCK_EX).should == 0;
    fixture.starts.bind(pending).should == false;
    flock(lock.fileno, LOCK_UN).should == 0;
    lock.close();

    fixture.starts.bind(pending).should == false;
    fixture.starts.refresh().should == false;
    fixture.store.get("held").session.id.should == "session-a";
}

@Name("A persistence failure leaves a collected intent retryable")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    fixture.store.register("held", "session-a");
    Call pending = startCall(fixture, "held", "done", "pending-session");
    pending.wait();
    pending.status.should == CallStatus.Succeeded;
    fixture.bridge.collect();
    pending.isCollected.should == true;

    string path = buildPath(fixture.store.directory, "state.json");
    string saved = readText(path);
    string target = buildPath(fixture.root, "persistence-target.json");
    string targetText = "fixture-only target";
    write(target, targetText);
    remove(path);
    symlink(target, path);
    bool linked = true;
    scope(exit)
    {
        if (linked && isSymlink(path))
        {
            remove(path);
            write(path, saved);
        }
    }

    fixture.starts.bind(pending).shouldThrow!Exception();
    fixture.store.get("held").session.id.should == "session-a";
    (fixture.store.profileFor(pending.sessionId) is null).should == true;
    readText(target).should == targetText;

    remove(path);
    linked = false;
    write(path, saved);
    fixture.starts.refresh().should == false;
    fixture.store.get("held").session.id.should == "pending-session";
}

@Name("Profile start reconciliation is bounded to the completion batch")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    Call[] accepted;
    foreach (i; 0..10)
    {
        string name = "profile-"~i.to!string;
        string session = "batch-"~i.to!string;
        Call execution = startCall(fixture, name, "done", session);
        accepted ~= execution;
        execution.wait();
        execution.status.should == CallStatus.Succeeded;
    }

    waitUntil(delegate bool() {
        fixture.bridge.collect();
        foreach (execution; accepted)
        {
            if (!execution.isCollected)
                return false;
        }
        return true;
    });
    fixture.starts.refresh().should == true;
    fixture.store.list().length.should == 8;
    fixture.starts.refresh().should == false;
    fixture.store.list().length.should == 10;
}
