module tests.interop.devin.session.transcript;

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

@Name("Transcript lookup resolves historical execution ID and falls back to disk logs after memory eviction")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    installFake(fixture);

    Call call = fixture.bridge.print("durable transcript turn text", fixture.root);
    call.wait();
    string executionId = call.id;
    string sessionId = call.sessionId;

    call.settled = MonoTime.currTime - 301.seconds;
    fixture.bridge.collect();

    fixture.bridge.execution(executionId).shouldBeNull;

    string mappedSession = fixture.bridge.sessionForExecution(executionId);
    mappedSession.should == sessionId;

    JSONValue record = fixture.bridge.executionRecord(executionId);
    (record.type != JSONType.null_).should == true;
    record["id"].str.should == executionId;
    record["status"].str.should == "succeeded";

    string outPath = buildPath(fixture.bridge.executionDir, executionId~".out");
    exists(outPath).should == true;
    readText(outPath).canFind("durable transcript turn text").should == true;
}

@Name("Transcript endpoint resolves managed session even after call ticket is evicted") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    JSONValue res = hookSession(fixture, "managed-hist-session");

    string callId = res["id"].str;
    callId.length.should == 36;

    JSONValue transcript = request("/api/executions/"~callId~"/transcript");
    (transcript["session"].type != JSONType.null_).should == true;
    transcript["session"]["id"].str.should == "managed-hist-session";
    (transcript["messages"].type == JSONType.array).should == true;
}
