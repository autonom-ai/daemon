module tests.bridge;

import autonom.interop : Execution, ExecutionStatus, Session, SessionStatus;
import tests.common : Fixture, waitUntil;
import unit_threaded : Name, should, shouldThrow;

import core.time : msecs;
import std.algorithm.searching : canFind;
import std.conv : octal;
import std.file : exists, readText, setAttributes, write;
import std.path : buildPath;
import std.string : splitLines, strip;

private:

void installCli(Fixture fixture)
{
    write(fixture.config.devinCommand, `#!/bin/sh
case "$1" in
    list)
        if [ -f "$(dirname "$0")/sessions.txt" ]; then
            printf '['
            separator=
            while read id; do
                printf '%s{"id":"%s"}' "$separator" "$id"
                separator=,
            done < "$(dirname "$0")/sessions.txt"
            printf ']'
        else
            printf '[{"id":"session-1"},{"id":"session-2"}]'
        fi
        echo noise >&2 ;;
    slow) sleep 5 ;;
    rm) [ "$4" = missing ] && { echo "no session" >&2; exit 1; }
        printf '%s\n' "$@" > "$(dirname "$0")/removed.txt" ;;
    --print)
        export_path=
        previous=
        for argument do
            if [ "$previous" = --export ]; then export_path=$argument; fi
            prompt=$argument
            previous=$argument
        done
        [ "$prompt" = fail ] && { echo broken >&2; exit 3; }
        echo session-3 >> "$(dirname "$0")/sessions.txt"
        printf '{"session_id":"session-3"}' > "$export_path"
        printf '%s ' "$@" ;;
    *) for argument do prompt="$argument"; done
       [ "$prompt" = fail ] && { echo broken >&2; exit 3; }
       printf '%s ' "$@" ;;
esac
`);
    setAttributes(fixture.config.devinCommand, octal!"700");
}

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
    Execution execution = fixture.bridge.print("hello $(world)", fixture.root, "SWE-2");
    execution.wait();
    execution.status.should == ExecutionStatus.Succeeded;
    execution.sessionId.should == "session-3";
    execution.toJSON()["reply"].str.canFind("hello $(world)").should == true;
    fixture.bridge.print("", fixture.root).shouldThrow!Exception();
}

@Name("Bridge reports CLI failures with stderr and enforces timeouts")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installCli(fixture);
    Execution failed = fixture.bridge.print("fail", fixture.root);
    failed.wait();
    failed.status.should == ExecutionStatus.Failed;
    failed.toJSON()["error"].str.should == "CLI command failed (exit 3)";
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
