module tests.bridge;

import autonom.session : Session;
import tests.common : Fixture, waitUntil;
import unit_threaded : Name, should, shouldThrow;

import core.time : msecs;
import std.conv : octal;
import std.file : exists, readText, setAttributes, write;
import std.path : buildPath;
import std.string : splitLines, strip;

private:

void installCli(Fixture fixture)
{
    write(fixture.config.devinCommand, `#!/bin/sh
case "$1" in
    list) printf '[{"id":"session-1"},{"id":"session-2"}]'; echo noise >&2 ;;
    slow) sleep 5 ;;
    rm) [ "$4" = missing ] && { echo "no session" >&2; exit 1; }
        printf '%s\n' "$@" > "$(dirname "$0")/removed.txt" ;;
    *) for argument do prompt="$argument"; done
       [ "$prompt" = fail ] && { echo broken >&2; exit 3; }
       printf '%s ' "$@" ;;
esac
`);
    setAttributes(fixture.config.devinCommand, octal!"700");
}

public:

@Name("Bridge lists CLI session IDs from stdout only")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture);
    fixture.bridge.list(fixture.root).should == ["session-1", "session-2"];
}

@Name("Bridge prints with a supplied model and literal prompt")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture);
    fixture.bridge.print("hello $(world)", fixture.root, "SWE-2").strip.should ==
        "--print --model SWE-2 -- hello $(world)";
    fixture.bridge.print("", fixture.root).shouldThrow!Exception();
}

@Name("Bridge reports CLI failures with stderr and enforces timeouts")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture);
    bool reported;
    try
        fixture.bridge.print("fail", fixture.root);
    catch (Exception error)
        reported = error.msg == "CLI command failed (exit 3): broken\n";

    reported.should == true;
    fixture.bridge.run(["slow"], fixture.root, 100.msecs).shouldThrow!Exception();
}

@Name("Session removal deletes the CLI session and its log")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture);
    Session session = fixture.bridge.session("session-1");
    session.start("work", fixture.root);
    waitUntil(delegate bool()
    {
        return !session.isRunning();
    });
    string log = buildPath(fixture.bridge.logDir, "session-1.log");
    exists(log).should == true;
    session.remove();
    readText(buildPath(fixture.root, "removed.txt")).splitLines.should == ["rm", "--force", "--", "session-1"];
    exists(log).should == false;
    fixture.bridge.remove("missing").shouldThrow!Exception();
}
