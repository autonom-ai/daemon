module tests.session;

import autonom.session : Session, SessionStatus;
import autonom.profilestore : ProfileConflict;
import tests.common : Fixture, waitUntil;
import unit_threaded : Name, Serial, should, shouldThrow;

import core.sys.linux.sys.file : flock, LOCK_EX;
import std.algorithm : canFind;
import std.array : replicate;
import std.conv : octal;
import std.file : exists, mkdirRecurse, readText, setAttributes, write;
import std.path : buildPath;
import std.process : environment;
import std.stdio : File;
import std.string : splitLines;

private:

void installCli(Fixture fixture)
{
    write(fixture.config.devinCommand, `#!/bin/sh
printf '%s\n' "$@" > arguments.txt
for argument do prompt="$argument"; done
[ "$prompt" = fail ] && exit 7
trap 'exit 0' TERM
while :; do sleep 0.05; done
`);
    setAttributes(fixture.config.devinCommand, octal!"700");
}

public:

@Name("Session rejects invalid IDs before launching")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    foreach (id; [
        "",
        "../escape",
        "white space",
        "-session",
        "a".replicate(129)
    ])
        fixture.bridge.session(id).shouldThrow!Exception();
}

@Name("Session online status follows the lock rather than file contents")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Session session = fixture.store.register("marlow", "session-1").session;
    mkdirRecurse(fixture.config.sessionLockDir);
    File lock = File(buildPath(fixture.config.sessionLockDir, session.id~".lock"), "w+");
    scope(exit)
    {
        if (lock.isOpen)
            lock.close();
    }

    session.isOnline().should == false;
    flock(lock.fileno, LOCK_EX).should == 0;
    session.inspect().should == SessionStatus.Online;
    session.stop().shouldThrow!Exception();
    fixture.store.register("marlow", "session-2").shouldThrow!ProfileConflict();
    lock.close();
    waitUntil(delegate bool()
    {
        return session.inspect() == SessionStatus.Offline;
    });
}

@Name("Session passes a supplied model and literal prompt arguments")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture);
    Session session = fixture.bridge.session("session-1");
    scope(exit)
        session.stop();

    string prompt = "--model dangerous; $(touch forbidden)";
    session.start(prompt, fixture.root, "SWE-2");
    waitUntil(delegate bool()
    {
        return exists(buildPath(fixture.root, "arguments.txt"));
    });
    readText(buildPath(fixture.root, "arguments.txt")).splitLines.should == [
        "--resume",
        "session-1",
        "--print",
        "--model",
        "SWE-2",
        "--",
        prompt
    ];
    exists(buildPath(fixture.root, "forbidden")).should == false;
}

@Name("Session rejects duplicate starts and active profile replacement")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture);
    Session session = fixture.store.register("marlow", "session-1").session;
    scope(exit)
        session.stop();

    session.start("work", fixture.root);
    session.start("work", fixture.root).shouldThrow!Exception();
    fixture.store.register("marlow", "session-2").shouldThrow!ProfileConflict();
}

@Name("Session stop reaps owned processes and permits restart")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture);
    Session session = fixture.bridge.session("session-1");
    scope(exit)
        session.stop();

    session.start("work", fixture.root);
    session.stop();
    session.isRunning().should == false;
    session.inspect().should == SessionStatus.Offline;
    session.start("again", fixture.root);
    session.isRunning().should == true;
}

@Name("Session strips host agent variables from the CLI environment") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    write(fixture.config.devinCommand, `#!/bin/sh
printenv > environ.tmp && mv environ.tmp environ.txt
while :; do sleep 0.05; done
`);
    setAttributes(fixture.config.devinCommand, octal!"700");

    Session session = fixture.bridge.session("session-1");
    scope(exit)
        session.stop();

    environment["ACP_BACKEND"] = "windsurf";
    environment["WINDSURF_IDE_TYPE"] = "windsurf";
    scope(exit)
    {
        environment.remove("ACP_BACKEND");
        environment.remove("WINDSURF_IDE_TYPE");
    }

    session.start("work", fixture.root);
    waitUntil(delegate bool()
    {
        return exists(buildPath(fixture.root, "environ.txt"));
    });
    string spawned = readText(buildPath(fixture.root, "environ.txt"));
    spawned.canFind("ACP_BACKEND=").should == false;
    spawned.canFind("WINDSURF_IDE_TYPE=").should == false;
    spawned.canFind("PATH=").should == true;
}

@Name("Session exposes a failed CLI exit independently of online status")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture);
    Session session = fixture.bridge.session("session-1");
    scope(exit)
        session.stop();

    session.start("fail", fixture.root);
    waitUntil(delegate bool()
    {
        return !session.isRunning();
    });
    session.inspect().should == SessionStatus.Failed;
    session.exitStatus.get.should == 7;
}
