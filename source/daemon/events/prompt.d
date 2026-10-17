module daemon.events.prompt;

import daemon.events.event : Event, EventType;
import daemon.events.schedule : Schedule;

import std.conv : to;
import std.datetime : Clock;
import std.file;

string durationText(long value)
{
    if (value % 86400 == 0)
        return (value / 86400).to!string~"d";
    if (value % 3600 == 0)
        return (value / 3600).to!string~"h";
    if (value % 60 == 0)
        return (value / 60).to!string~"m";

    return value.to!string~"s";
}

string clockText(Schedule schedule)
    => schedule.every ? "scheduled wake, repeats every "~durationText(schedule.every) : "scheduled wake";

string eventCountText(size_t count)
    => count == 1 ? "1 event" : count.to!string~" events";

string eventLine(Event event)
{
    if (event.type == EventType.Clock)
        return "- "~event.summary~" ("~event.text~")";

    return "- "~event.summary~": "~event.text;
}

string wakePrompt(Event[] batch, string owner)
{
    string ret = "You were woken by "~eventCountText(batch.length)~":\n\n";
    foreach (event; batch)
        ret ~= eventLine(event)~"\n";

    ret ~= "\n";
    ret ~= owner.length ? "This is a new session in "~owner~"'s workspace." : "Continue your work.";
    return ret;
}
