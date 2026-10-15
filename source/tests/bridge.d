module tests.bridge;

import daemon.interop;
import tests.common;
import unit_threaded : Name, should, shouldThrow;

import core.time : msecs;
import std.algorithm.searching : canFind;
import std.conv : octal;
import std.file;
import std.path : buildPath;
import std.string : splitLines, strip;

private:

public:

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

@Name("Bridge lists CLI session IDs from stdout only")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    fixture.bridge.list(fixture.root).should == ["session-1", "session-2"];
}

@Name("Bridge prints with a supplied model and literal prompt")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    Execution execution = fixture.bridge.print("hello $(world)", fixture.root, "SWE-2");
    execution.wait();
    execution.status.should == ExecutionStatus.Succeeded;
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
    Execution failed = fixture.bridge.print("fail", fixture.root);
    failed.wait();
    failed.status.should == ExecutionStatus.Failed;
    failed.toJSON()["error"].str.canFind("prompt failed").should == true;
    fixture.bridge.run(["slow"], fixture.root, 100.msecs).shouldThrow!Exception();
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
    waitUntil(delegate bool()
    {
        return session.status == SessionStatus.Offline;
    });
    string log = buildPath(fixture.bridge.logDir, "session-1.log");
    exists(log).should == true;
    session.remove();
    readText(buildPath(fixture.root, "removed.txt")).splitLines.should == ["rm", "--force", "--", "session-1"];
    exists(log).should == false;
    Execution missing = fixture.bridge.remove("missing");
    missing.wait();
    missing.status.should == ExecutionStatus.Failed;
}
