module tests.events.common;

import daemon.agent : Profile, ProfileStore;
import daemon.agent.starts : ProfileStarts;
import daemon.config : Config;
import daemon.coord : Bus, Entry;
import daemon.events.api : schedules;
import daemon.events.event : EventStore;
import daemon.events.schedule : ScheduleStore;
import daemon.events.scheduler : Scheduler;
import daemon.interop.call : Call, CallStatus;
import daemon.interop.devin.bridge : Bridge;
import tests.common : Fixture, installFake, waitUntil;

import arsd.sqlite : Database, Sqlite, SQLITE_OPEN_READWRITE, SQLITE_OPEN_CREATE;
import unit_threaded : should;

import std.algorithm.searching : canFind;
import std.file : exists, write, readText;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.string : split, splitLines, strip;

void installCli(Fixture fixture)
    => installFake(fixture);

void installFailingCli(Fixture fixture)
{
    write(buildPath(fixture.root, "fail-prompt"), "");
}

void writeSessionDatabase(
    string path,
    string id,
    string model,
    string directory
)
{
    Database database = new Sqlite(path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    database.query("create table if not exists sessions (id text primary key, model text, working_directory text, "~
        "title text, agent_mode text default 'bypass', backend_type text default 'cli', created_at integer default 0, "~
        "last_activity_at integer default 0, hidden integer default 0, workspace_dirs text default '[]', metadata text)");
    database.query(
        "insert or replace into sessions (id, model, working_directory) values (?, ?, ?)",
        id,
        model,
        directory
    );
}

string[] invocations(string workspace)
{
    string path = buildPath(workspace, "invocations.txt");
    if (!exists(path))
        return null;

    string[] ret;
    foreach (call; readText(path).split("---"))
    {
        if (call.strip.length)
            ret ~= call;
    }

    return ret;
}

JSONValue[] acpCalls(string workspace)
{
    string path = buildPath(workspace, "acp-calls.jsonl");
    if (!exists(path))
        return null;

    JSONValue[] ret;
    foreach (line; readText(path).splitLines())
    {
        if (line.strip.length)
            ret ~= parseJSON(line);
    }

    return ret;
}

string[] promptTexts(string workspace)
{
    string[] ret;
    foreach (call; acpCalls(workspace))
    {
        if ("method" in call.object && call["method"].str == "session/prompt")
            ret ~= call["text"].str;
    }

    return ret;
}

void waitForPrompt(WakeFixture fixture, string needle)
{
    waitUntil(delegate bool() {
        try
        {
            string[] prompts = promptTexts(fixture.fixture.root);
            return prompts.length && prompts[$-1].canFind(needle);
        }
        catch (Exception)
            return false;
    });
}

struct WakeFixture
{
    Fixture fixture;
    Config config;
    Bridge bridge;
    ProfileStore store;
    ProfileStarts starts;
    Bus bus;
    EventStore events;
    ScheduleStore schedules;
    Scheduler scheduler;

    static WakeFixture create(string extra = null)
    {
        WakeFixture ret;
        ret.fixture = Fixture.create("./devin", extra);
        scope(failure)
            ret.fixture.close();

        ret.config = ret.fixture.config;
        ret.bridge = ret.fixture.bridge;
        ret.store = ret.fixture.store;
        ret.starts = ret.fixture.starts;
        ret.events = new EventStore(ret.config, ret.store);
        ret.bus = new Bus(ret.config, ret.store);
        ret.schedules = new ScheduleStore(ret.config, ret.store);
        ret.scheduler = new Scheduler(ret.config, ret.bridge, ret.store, ret.events, ret.schedules,
            ret.starts);
        return ret;
    }

    Profile start(string name)
    {
        Call execution = bridge.start("work", fixture.root, "");
        execution.wait();
        execution.status.should == CallStatus.Succeeded;
        bridge.collect();
        return store.register(name, execution.sessionId);
    }

    void close()
    {
        scheduler.stop();
        starts.close();
        bridge.close();
        fixture.close();
    }
}

Entry postedEntry(Profile from, string text, string room = null)
    => Entry.create(from.name, text, null, room);
