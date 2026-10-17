module daemon.events.wake;

import daemon.agent;
import daemon.events.event : Event;
import daemon.events.scheduler : Scheduler, wakesFile;
import daemon.interop.call;
import daemon.storage;

import std.file;
import std.json : JSONType, JSONValue;
import std.path : buildNormalizedPath, buildPath;

bool adopt(Scheduler owner, string session, string directory, string execution = null)
{
    if (!session.length || !directory.length)
        return false;

    Profile existing;
    try
        existing = owner.store.profileFor(session);
    catch (Exception)
        return false;

    if (existing !is null)
        return false;

    directory = buildNormalizedPath(directory);
    size_t candidate = size_t.max;
    foreach (i, ref wake; owner.pendingWakes)
    {
        if (wake.session.length || !wake.workspace.length)
            continue;
        if (execution.length && wake.execution != execution)
            continue;
        if (buildNormalizedPath(wake.workspace) != directory)
            continue;
        if (candidate != size_t.max)
            return false;

        candidate = i;
    }

    if (candidate == size_t.max)
        return false;

    Profile profile = owner.store.get(owner.pendingWakes[candidate].profile);
    if (profile is null)
        return false;

    try
        owner.store.register(profile.name, session);
    catch (Exception)
        return false;

    owner.pendingWakes[candidate].session = session.idup;
    owner.saveWakes();
    return true;
}

private string wakesPath(const Scheduler owner)
    => buildPath(owner.schedules.directory, wakesFile);

private bool parseWake(JSONValue data, out PendingWake wake)
{
    if (data.type != JSONType.object)
        return false;

    foreach (field; ["execution", "profile", "session", "workspace", "events"])
    {
        if (field !in data.object)
            return false;
    }

    if (data["execution"].type != JSONType.string || data["profile"].type != JSONType.string ||
        data["workspace"].type != JSONType.string || data["events"].type != JSONType.array)
        return false;
    if (!data["session"].isNull && data["session"].type != JSONType.string)
        return false;

    wake.execution = data["execution"].str.idup;
    wake.profile = data["profile"].str.idup;
    wake.session = data["session"].isNull ? null : data["session"].str.idup;
    wake.workspace = data["workspace"].str.idup;
    foreach (entry; data["events"].array)
    {
        Event event;
        if (!Event.parse(entry, event))
            return false;

        wake.events ~= event;
    }

    return true;
}

package(daemon.events) void loadWakes(Scheduler owner)
{
    if (!exists(owner.wakesPath))
        return;

    JSONValue data = readJSON(owner.wakesPath, 4 * 1024 * 1024);
    if (data.type != JSONType.object || "version" !in data.object || data["version"] != JSONValue(1) ||
        "wakes" !in data.object || data["wakes"].type != JSONType.array)
        throw new Exception("Invalid pending wakes");

    foreach (entry; data["wakes"].array)
    {
        PendingWake wake;
        if (!parseWake(entry, wake))
            throw new Exception("Invalid pending wake");

        owner.pendingWakes ~= wake;
    }
}

private void saveWakes(Scheduler owner)
{
    JSONValue data = JSONValue.emptyObject;
    data["version"] = JSONValue(1);
    data["wakes"] = JSONValue.emptyArray;
    foreach (wake; owner.pendingWakes)
    {
        JSONValue eventsJSON = JSONValue.emptyArray;
        foreach (event; wake.events)
            eventsJSON.array ~= event.toJSON();

        data["wakes"].array ~= JSONValue([
            "execution": JSONValue(wake.execution),
            "profile": JSONValue(wake.profile),
            "session": wake.session.length ? JSONValue(wake.session) : JSONValue(null),
            "workspace": JSONValue(wake.workspace),
            "events": eventsJSON
        ]);
    }

    mkdirRecurse(owner.schedules.directory);
    atomicWrite(owner.wakesPath, data.toString());
}

package(daemon.events) void recordWake(
    Scheduler owner,
    string execution,
    string profileName,
    string session,
    string workspace,
    Event[] batch
)
{
    PendingWake wake;
    wake.execution = execution;
    wake.profile = profileName;
    wake.session = session;
    wake.workspace = workspace;
    wake.events = batch;
    owner.pendingWakes ~= wake;
    owner.saveWakes();
}

package(daemon.events) bool wakeInFlight(Scheduler owner, string profileName)
{
    foreach (wake; owner.pendingWakes)
    {
        if (wake.profile == profileName)
            return true;
    }

    return false;
}

private void register(Scheduler owner, string profileName, string session)
{
    Profile profile = owner.store.get(profileName);
    if (profile is null)
        return;

    try
        owner.store.register(profile.name, session);
    catch (Exception)
    { }
}

package(daemon.events) void reconcile(Scheduler owner)
{
    if (!owner.pendingWakes.length)
        return;

    PendingWake[] remaining;
    bool changed;
    foreach (wake; owner.pendingWakes)
    {
        Call execution = owner.bridge.execution(wake.execution);
        if (execution !is null && execution.running)
        {
            remaining ~= wake;
            continue;
        }

        changed = true;
        if (execution !is null && execution.status == CallStatus.Succeeded)
        {
            if (execution.kind == CallKind.Start && execution.sessionId.length && !wake.session.length)
                owner.register(wake.profile, execution.sessionId);
        }
        else
        {
            Profile profile = owner.store.get(wake.profile);
            if (profile !is null)
            {
                foreach (event; wake.events)
                    owner.events.surface(profile, event);
            }
        }
    }

    if (changed)
    {
        owner.pendingWakes = remaining;
        owner.saveWakes();
    }
}

package(daemon.events) struct PendingWake
{
    string execution;
    string profile;
    string session;
    string workspace;
    Event[] events;
}
