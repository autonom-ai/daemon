module daemon.events.delivery;

import daemon.agent;
import daemon.coord;
import daemon.events.event : Event, EventType;
import daemon.events.scheduler : Scheduler;

void posted(
    Scheduler owner,
    Room room,
    Entry entry,
    Profile from,
    Profile[] targets
)
{
    Event[][string] batch;
    Profile[string] profiles;
    foreach (match; owner.schedules.matching(EventType.Room, room.name, from.name))
    {
        if (match.profile.name == from.name || !room.visible(match.profile.name))
            continue;

        queue(batch, profiles, match.profile, Event.create(
            EventType.Room,
            entry.id,
            from.name,
            entry.text,
            room.name,
            match.schedule.id
        ));
    }

    owner.queuePings(batch, profiles, targets, from, entry, room.name);
    owner.deliverAll(batch, profiles, from);
}

void directed(
    Scheduler owner,
    Profile to,
    Entry entry,
    Profile from,
    Profile[] targets
)
{
    Event[][string] batch;
    Profile[string] profiles;
    foreach (match; owner.schedules.matching(EventType.DM, null, from.name))
    {
        if (match.profile.name != to.name)
            continue;

        queue(batch, profiles, match.profile, Event.create(
            EventType.DM,
            entry.id,
            from.name,
            entry.text,
            null,
            match.schedule.id
        ));
    }

    owner.queuePings(batch, profiles, targets, from, entry, null);
    owner.deliverAll(batch, profiles, from);
}

private string pingSchedule(Scheduler owner, Profile profile, string from)
{
    foreach (match; owner.schedules.matching(EventType.Ping, null, from))
    {
        if (match.profile.name == profile.name)
            return match.schedule.id;
    }

    return null;
}

private void queue(ref Event[][string] batch, ref Profile[string] profiles, Profile profile, Event event)
{
    batch[profile.name] ~= event;
    profiles[profile.name] = profile;
}

private void queuePings(
    Scheduler owner,
    ref Event[][string] batch,
    ref Profile[string] profiles,
    Profile[] targets,
    Profile from,
    Entry entry,
    string room
)
{
    foreach (target; targets)
    {
        if (target.name == from.name)
            continue;

        queue(batch, profiles, target, Event.create(
            EventType.Ping,
            entry.id,
            from.name,
            entry.text,
            room,
            owner.pingSchedule(target, from.name)
        ));
    }
}

private void deliverAll(Scheduler owner, Event[][string] batch, Profile[string] profiles, Profile from)
{
    foreach (name, events; batch)
        owner.deliver(profiles[name], events, from);
}
