module tests.http.events;

import daemon.events.event : Event, EventStore, EventType;
import tests.common;
import tests.http.common;

import unit_threaded : Name, Serial, should;

import core.thread : Thread;
import core.time : msecs;
import std.array : replicate;
import std.conv : to;
import std.json : JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.process;

@Name("Daemon schedules wakes and reads events") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    static foreach (name; ["marlow", "wren"])
        request("/api/profiles", 201, JSONValue(["name": JSONValue(name)]).toString());
    request("/api/profiles/marlow/session", 200, `{"id":"session-1"}`);
    request("/api/profiles/wren/session", 200, `{"id":"session-2"}`);

    request("/api/schedules").array.length.should == 0;
    request("/api/schedules?session=missing", 409);
    request("/api/schedules?session=session-1", 405, null, "application/json", HTTP.Method.del);
    request("/api/schedules?session=session-1", 400, `{"type":"unknown"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"clock"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"clock","at":"nope"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"clock","at":"2020-01-01T00:00:00Z"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"clock","every":0}`);
    request("/api/schedules?session=session-1", 400, `{"type":"clock","every":10,"at":"2030-01-01T00:00:00Z"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"room"}`);
    request("/api/schedules?session=session-1", 404, `{"type":"room","room":"missing"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"ping","from":"missing"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"ping","room":"general"}`);
    request("/api/schedules?session=session-1", 400, `{"type":"ping","unknown":true}`);
    request("/api/events")["events"].array.length.should == 0;
    request("/api/events?session=missing", 409);
    request("/api/events?session=session-2", 400, "{}", "application/json", HTTP.Method.post);
    request("/api/events?session=session-2", 405, null, "application/json", HTTP.Method.del);

    JSONValue created = request("/api/schedules?session=session-1", 201, `{"type":"ping","from":"wren"}`);
    created["type"].str.should == "ping";
    created["from"].str.should == "wren";
    created["room"].should == JSONValue(null);
    created["every"].should == JSONValue(null);
    request("/api/schedules?session=session-1").array.length.should == 1;
    request("/api/schedules?session=session-2").array.length.should == 0;
    request("/api/schedules?session=session-1", 400, `{"type":"ping","from":"wren","extra":true}`);
    request("/api/schedules/refresh", 400, "{");
    request("/api/schedules/refresh", 400, `{"unexpected":true}`);
    request("/api/schedules/refresh", 200, "{}").should == parseJSON("{}");
    request("/api/events?session=session-2")["events"].array.length.should == 0;

    request("/api/messages?session=session-2", 201, `{"to":"marlow","text":"scheduled","ping":["marlow"]}`);
    JSONValue scheduled = request("/api/events?session=session-1");
    scheduled["events"].array.length.should == 1;
    scheduled["events"].array[0]["type"].str.should == "ping";
    scheduled["events"].array[0]["schedule"].str.should == created["id"].str;

    request(
        "/api/schedules/"~created["id"].str~"?session=session-1",
        200,
        null,
        "application/json",
        HTTP.Method.del
    )["id"].str.should == created["id"].str;
    request("/api/schedules/"~created["id"].str~"?session=session-1", 404, null, "application/json", HTTP.Method.del);
    request("/api/schedules?session=session-1").array.length.should == 0;

    JSONValue clock = request("/api/schedules?session=session-1", 201, `{"type":"clock","every":1}`);
    clock["every"].integer.should == 1;
    (clock["next"].integer > 0).should == true;
    Thread.sleep(1100.msecs);
    request("/api/schedules/refresh", 200, "{}");
    request(
        "/api/schedules/"~clock["id"].str~"?session=session-1",
        200,
        null,
        "application/json",
        HTTP.Method.del
    );
    JSONValue fired = request("/api/events?session=session-1");
    (fired["events"].array.length >= 1).should == true;
    fired["events"].array[0]["type"].str.should == "clock";
    fired["events"].array[0]["text"].str.should == "scheduled wake, repeats every 1s";
    request("/api/events?session=session-1")["events"].array.length.should == 0;
}

@Name("Event peek and scoped acknowledgement preserve arrivals after display") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    EventStore seed = new EventStore(fixture.config, fixture.store);
    seed.surface(fixture.store.register("marlow", "marlow-session"),
        Event.create(EventType.Ping, "shown", "human", "first"));
    seed.surface(fixture.store.register("wren", "wren-session"),
        Event.create(EventType.Ping, "foreign", "human", "another inbox"));
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    foreach (i; 0..2)
    {
        JSONValue peek = request("/api/events?profile=marlow&peek=true");
        peek["events"].array.length.should == 1;
        peek["events"][0]["id"].str.should == "shown";
    }
    request("/api/events?profile=marlow&peek=invalid", 400);
    request("/api/events?profile=marlow&peek=", 400);
    foreach (body; [`{}`, `{"ids":null}`, `{"ids":"shown"}`, `{"ids":[1]}`,
        `{"ids":[""]}`, `{"ids":["shown"],"extra":true}`])
        request("/api/events?profile=marlow", 400, body);
    request("/api/events?profile=marlow", 400,
        JSONValue(["ids": JSONValue(["id".replicate(257)])]).toString());
    request("/api/events?profile=marlow", 400,
        JSONValue(["ids": JSONValue(["shown"].replicate(1001))]).toString());
    request("/api/events?profile=marlow&peek=true")["events"].array.length.should == 1;

    request("/api/schedules?profile=marlow", 201, `{"type":"ping","from":"human"}`);
    request("/api/messages", 201, `{"to":"marlow","text":"later","ping":["marlow"]}`);
    request("/api/events?profile=marlow&peek=true")["events"].array.length.should == 2;
    JSONValue acknowledged = request("/api/events?profile=marlow", 200, `{"ids":["shown","shown","foreign"]}`);
    acknowledged["acknowledged"].array.should == [JSONValue("shown")];
    request("/api/events?profile=marlow", 200, `{"ids":["shown"]}`)["acknowledged"].array.length.should == 0;
    request("/api/events?profile=marlow", 200, `{"ids":[]}`)["acknowledged"].array.length.should == 0;
    JSONValue remaining = request("/api/events?profile=marlow&peek=true");
    remaining["events"].array.length.should == 1;
    remaining["events"][0]["text"].str.should == "later";
    request("/api/events?profile=wren&peek=true")["events"][0]["id"].str.should == "foreign";

    string capability = "a".replicate(64);
    request("/api/acp/admit", 200, JSONValue([
        "connection": JSONValue("00000000-0000-0000-0000-000000000001"),
        "session": JSONValue("marlow-session"),
        "token": JSONValue(capability)
    ]).toString());
    request("/api/events?profile=wren", 200, `{"ids":["foreign"]}`, "application/json",
        HTTP.Method.post, null, "marlow-session", false, capability)["acknowledged"].array.length.should == 0;
    request("/api/events?profile=wren&peek=true")["events"][0]["id"].str.should == "foreign";

    request("/api/events?profile=marlow&peek=false")["events"].array.length.should == 1;
    request("/api/events?profile=marlow")["events"].array.length.should == 0;
}
