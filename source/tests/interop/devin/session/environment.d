module tests.interop.devin.session.environment;

import daemon.agent;
import daemon.config : Config;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.calls;
import daemon.interop.devin.history;
import daemon.interop.devin.session.api : removeSessions;
import daemon.interop.devin.session.catalog;
import daemon.interop.devin.session.control;
import daemon.interop.session;
import daemon.interop;
import tests.common;
import tests.http.common;

import serverino : endpoint, route;
import unit_threaded;

import core.sys.linux.sys.file : flock, LOCK_EX;
import core.time : MonoTime, minutes, seconds;
import std.algorithm : canFind;
import std.array : replicate;
import std.conv : to;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.process : environment;
import std.stdio : File;
import std.traits : hasUDA;

@Name("Session removes ACP routing and preserves the remaining CLI environment") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);
    write(buildPath(fixture.root, "want-environ"), "");

    Session session = fixture.bridge.session("session-1");
    scope(exit)
        session.stop();

    string[string] supplied = [
        "ACP_BACKEND": "windsurf",
        "ACP_CUSTOM": "test-acp",
        "OPENROUTER_API_KEY": "test-router-key",
        "WINDSURF_IDE_TYPE": "windsurf",
        "ELECTRON_CUSTOM": "test-electron",
        "VSCODE_CUSTOM": "test-vscode"
    ];
    string[string] previous;
    foreach (name, val; supplied)
    {
        previous[name] = environment.get(name);
        environment[name] = val;
    }
    scope(exit)
    {
        foreach (name, val; previous)
        {
            if (val is null)
                environment.remove(name);
            else
                environment[name] = val;
        }
    }

    session.resume("hang", fixture.root);
    waitUntil(delegate bool() {
        return exists(buildPath(fixture.root, "environ.txt"));
    });
    string spawned = readText(buildPath(fixture.root, "environ.txt"));
    spawned.canFind("ACP_BACKEND=").should == false;
    foreach (name, val; supplied)
    {
        if (name != "ACP_BACKEND")
            spawned.canFind(name~"="~val).should == true;
    }
    spawned.canFind("PATH=").should == true;
    spawned.canFind("CHISEL_SESSION_DB="~buildPath(fixture.config.dataDir, "cli", "sessions.db")).should == true;
}
