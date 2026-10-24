module tests.interop.devin.bridge;

import daemon.interop.call : CallResult;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.prompt : promptResult;
import daemon.interop.devin.session.control : remove;
import daemon.interop;
import tests.common;

import unit_threaded : Name, should, shouldThrow;

import core.time : msecs;
import std.algorithm.searching : canFind;
import std.file;
import std.json : parseJSON;
import std.path : buildPath;
import std.string : splitLines;

@Name("Bridge owns one canonical handle per session independently of profiles")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    char[] buffer = "session-1".dup;
    Session session = fixture.bridge.session(cast(string)buffer);
    buffer[] = 'X';
    session.id.should == "session-1";
    (fixture.bridge.session("session-1") is session).should == true;
    (fixture.store.register("marlow", "session-1").session is session).should == true;
}

@Name("Bridge prints with a supplied model and literal prompt")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    Call execution = fixture.bridge.print("hello $(world)", fixture.root, "SWE-2");
    execution.wait();
    execution.status.should == CallStatus.Succeeded;
    (execution.sessionId.length != 0).should == true;
    execution.toJSON()["reply"].str.canFind("hello $(world)").should == true;
    fixture.bridge.print("", fixture.root).shouldThrow!Exception();
}

@Name("Bridge reports agent failures and enforces timeouts")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    Call failed = fixture.bridge.print("fail", fixture.root);
    failed.wait();
    failed.status.should == CallStatus.Failed;
    failed.toJSON()["error"].str.canFind("prompt failed").should == true;
    fixture.bridge.executionTimeout = 100.msecs;
    Call timedOut = fixture.bridge.print("hang", fixture.root);
    timedOut.wait();
    timedOut.status.should == CallStatus.Interrupted;
    timedOut.toJSON()["error"].str.canFind("timed out").should == true;
}

@Name("Confirmed completion wins a cancellation request that the peer did not confirm")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    Call execution = fixture.bridge.print("complete-on-cancel", fixture.root);
    waitUntil(delegate bool() {
        string calls = buildPath(fixture.root, "acp-calls.jsonl");
        return exists(calls) && readText(calls).canFind("complete-on-cancel");
    });
    execution.stop();
    execution.status.should == CallStatus.Succeeded;
    execution.toJSON()["stopReason"].str.should == "end_turn";
}

@Name("Prompt result decoding rejects malformed terminal replies and preserves confirmed outcomes")
unittest
{
    foreach (reply; [`null`, `[]`, `{}`, `{"stopReason":7}`, `{"stopReason":"unknown"}`])
        (promptResult(parseJSON(reply)).error.length > 0).should == true;

    promptResult(parseJSON(`{"stopReason":"cancelled"}`)).cancelled.should == true;
    CallResult completed = promptResult(parseJSON(`{"stopReason":"end_turn","future":true}`));
    completed.cancelled.should == false;
    completed.error.length.should == 0;
}

@Name("Session removal deletes the CLI session and its log")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    Session session = fixture.bridge.session("session-1");
    session.resume("work", fixture.root);
    session.execution.wait();
    session.execution.status.should == CallStatus.Succeeded;
    session.status.should == SessionStatus.Offline;
    string log = buildPath(fixture.bridge.logDir, "session-1.log");
    exists(log).should == true;
    session.remove();
    readText(buildPath(fixture.root, "removed.txt")).splitLines.should == ["rm", "--force", "--", "session-1"];
    exists(log).should == false;
    Call missing = fixture.bridge.remove("missing");
    missing.wait();
    missing.status.should == CallStatus.Failed;
}

@Name("Compaction and resume share one loaded connection without leaking compaction output")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    installFake(fixture);

    Call first = fixture.bridge.start("work", fixture.root);
    first.wait();
    Call resumed = fixture.bridge.resume(first.sessionId, "continue", fixture.root, null, true);
    resumed.wait();
    resumed.status.should == CallStatus.Succeeded;
    resumed.toJSON()["reply"].str.should == "continue";
    readText(resumed.outputPath).should == "continue";
}

@Name("Failed or cancelled compaction never delivers the resume prompt")
unittest
{
    foreach (marker; ["fail-compact", "hang-compact"])
    {
        Fixture fixture = Fixture.create();
        scope(exit)
            fixture.close();
        installFake(fixture);

        Call first = fixture.bridge.start("work", fixture.root);
        first.wait();
        write(buildPath(fixture.root, marker), "");
        Call resumed = fixture.bridge.resume(first.sessionId, "must not run", fixture.root, null, true);
        waitUntil(delegate bool() {
            return readText(buildPath(fixture.root, "acp-calls.jsonl")).canFind("/compact");
        });
        if (marker == "hang-compact")
            resumed.stop();
        else
            resumed.wait();

        resumed.status.should == (marker == "hang-compact" ? CallStatus.Stopped : CallStatus.Failed);
        readText(buildPath(fixture.root, "acp-calls.jsonl")).canFind("must not run").should == false;
    }
}
