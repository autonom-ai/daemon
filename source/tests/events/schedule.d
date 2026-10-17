module tests.events.schedule;

import daemon.agent : Profile;
import daemon.coord : Room;
import daemon.coord.stream : stdTimeTicksPerMillisecond;
import daemon.events.api : schedules, schedule;
import daemon.events.event : EventType;
import daemon.events.schedule : Schedule, ScheduleStore, Match;
import daemon.interop.devin.session.control : remove;
import tests.common : Fixture;

import unit_threaded : Name, should;

import std.datetime : Clock, UTC;
import std.file : remove;
import std.typecons : Nullable;

@Name("Schedules persist, match, and advance")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile marlow = fixture.store.register("marlow", "session-1");
    Profile wren = fixture.store.register("wren", "session-2");
    ScheduleStore schedules = new ScheduleStore(fixture.config, fixture.store);
    Schedule ping = schedules.add(marlow, Schedule.create(EventType.Ping, "wren", null, null, 0, 0));
    Schedule room = schedules.add(marlow, Schedule.create(EventType.Room, null, "general", null, 0, 0));
    schedules.list(marlow).length.should == 2;

    ScheduleStore reloaded = new ScheduleStore(fixture.config, fixture.store);
    reloaded.list(marlow).length.should == 2;
    reloaded.list(wren).length.should == 0;
    reloaded.matching(EventType.Ping, null, "wren").length.should == 1;
    reloaded.matching(EventType.Ping, null, "quill").length.should == 0;
    reloaded.matching(EventType.Room, "general", "quill").length.should == 1;
    reloaded.matching(EventType.Room, "other", "quill").length.should == 0;

    long now = Clock.currTime(UTC()).stdTime / stdTimeTicksPerMillisecond;
    reloaded.add(marlow, Schedule.create(EventType.Clock, null, null, null, 60, now - 1));
    Match[] due = reloaded.due(Clock.currTime(UTC()));
    due.length.should == 1;
    reloaded.advance(marlow, due[0].schedule, Clock.currTime(UTC()));
    reloaded.due(Clock.currTime(UTC())).length.should == 0;
    reloaded.list(marlow).length.should == 3;
    (reloaded.list(marlow)[2].next > now).should == true;

    reloaded.add(marlow, Schedule.create(EventType.Clock, null, null, "2026-01-01T00:00:00Z", 0, now - 1));
    due = reloaded.due(Clock.currTime(UTC()));
    due.length.should == 1;
    reloaded.advance(marlow, due[0].schedule, Clock.currTime(UTC()));
    reloaded.list(marlow).length.should == 3;

    Nullable!Schedule removed = reloaded.remove(marlow, room.id);
    removed.isNull.should == false;
    removed.get.id.should == room.id;
    reloaded.remove(marlow, ping.id).isNull.should == false;
    reloaded.remove(marlow, ping.id).isNull.should == true;
    reloaded.list(marlow).length.should == 1;
}
