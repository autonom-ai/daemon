/// Worker-owned admission registry for profile-scoped session starts. Accepted
/// intents are resolved only on the worker after provider delivery; admission
/// state is transport-agnostic and never persisted.
module daemon.agent.starts;

import daemon.agent.profile : BindingGeneration, Profile, humanName;
import daemon.agent.store : canonicalName, ProfileConflictException, ProfileStore;
import daemon.exception : ConflictException, InvalidInputException;
import daemon.interop.call : Call;
import daemon.interop.completion : completionBatchLimit;
import daemon.interop.provider : IProvider;

import core.thread : Thread;
import std.algorithm : min, sort;
import std.process : thisProcessID;

/// Owns pending and current profile-scoped starts on the single worker thread.
class ProfileStarts
{
private:
    /// One accepted start intent plus the identity snapshot it must still match.
    class Intent
    {
        string name;
        string executionId;
        Call call;
        Profile profile;
        BindingGeneration marker;
        Call expectedExecution;
    }

    ProfileStore store;
    IProvider bridge;
    Thread creator;
    typeof(thisProcessID) creatorPid;
    Intent[string] intents;
    Intent[string] current;
    bool stopped;

    void requireWorker(string operation) const
    {
        if (Thread.getThis() !is creator || thisProcessID != creatorPid)
            throw new InvalidInputException("ProfileStarts." ~ operation ~
                " may only run on the worker thread");
    }

public:
    this(ProfileStore store, IProvider bridge)
    {
        this.store = store;
        this.bridge = bridge;
        creator = Thread.getThis();
        creatorPid = thisProcessID;
    }

    /// Admits one profile-scoped start: reserves the name before the provider
    /// launch and restores any previous reservation if the launch throws.
    Call start(string name, string prompt, string directory, string model = null,
        string mode = null, bool trusted = false)
    {
        requireWorker("start");
        if (stopped)
            throw new InvalidInputException("Profile start admission is closed");

        string canonical = canonicalName(name);
        if (canonical == humanName)
            throw new InvalidInputException("Invalid profile name");

        Profile profile = store.get(canonical);
        if (profile !is null && profile.session !is null &&
            (profile.session.hasActiveCall() || bridge.online(profile.session.id)))
            throw new ConflictException("Profile is already active");
        if (Intent* active = canonical in current)
        {
            if ((*active).call !is null && (*active).call.running)
                throw new ConflictException("Profile already has a starting session");
        }
        foreach (execution; bridge.listCalls())
        {
            if (execution.running && execution.profileName == canonical)
                throw new ConflictException("Profile already has a starting session");
        }

        Intent intent = new Intent();
        intent.name = canonical;
        intent.profile = profile;
        intent.marker = profile is null ? null : profile.bindingGeneration;
        intent.expectedExecution = profile is null || profile.session is null ?
            null : profile.session.execution;
        Intent* previous = canonical in current;
        Intent prior = previous is null ? null : *previous;
        current[canonical] = intent;
        scope(failure)
        {
            Intent* held = canonical in current;
            if (held !is null && *held is intent)
            {
                if (prior is null)
                    current.remove(canonical);
                else
                    *held = prior;
            }
        }

        Call ret = bridge.start(prompt, directory, model, mode, trusted, canonical);
        intent.call = ret;
        intent.executionId = ret.id;
        intents[ret.id] = intent;
        return ret;
    }

    /// Publishes an early binding while the accepted call still owns the intent.
    /// Returns false without side effects for unknown, superseded, or stale
    /// intents; persistence failures still propagate.
    bool bind(Call execution)
    {
        requireWorker("bind");
        if (stopped || execution is null)
            return false;
        Intent* found = execution.id in intents;
        if (found is null || (*found).call !is execution)
            return false;
        Intent intent = *found;
        Intent* active = intent.name in current;
        if (active is null || *active !is intent)
            return false;

        Profile profile = store.get(intent.name);
        if (profile !is intent.profile)
            return false;
        if (profile !is null)
        {
            if (profile.bindingGeneration !is intent.marker)
                return false;
            Call expected = profile.session is null ? null : profile.session.execution;
            if (expected !is intent.expectedExecution)
                return false;
        }

        string session = execution.sessionId;
        if (!session.length || !bridge.access.managed(session))
            return false;

        Profile published;
        try
            published = store.register(intent.name, session);
        catch (ProfileConflictException)
        {
            current.remove(intent.name);
            return false;
        }
        intent.profile = published;
        intent.marker = published.bindingGeneration;
        intent.expectedExecution = published.session is null ?
            null : published.session.execution;
        return true;
    }

    /// Resolves up to completionBatchLimit settled collected intents; returns
    /// whether more eligible work remains so the worker can schedule a pass.
    bool refresh()
    {
        requireWorker("refresh");
        if (stopped)
            return false;

        Intent[] ready;
        foreach (intent; intents)
        {
            if (intent.call is null || intent.call.running || !intent.call.isCollected)
                continue;
            ready ~= intent;
        }
        ready.sort!((left, right) => left.call.createdAt < right.call.createdAt);
        bool more = ready.length > completionBatchLimit;
        foreach (intent; ready[0 .. min(ready.length, completionBatchLimit)])
        {
            bind(intent.call);
            intents.remove(intent.executionId);
            Intent* active = intent.name in current;
            if (active !is null && *active is intent)
                current.remove(intent.name);
        }
        return more;
    }

    /// Closes admission and drops transient intent references; start rejects
    /// and bind and refresh become inert.
    void close()
    {
        requireWorker("close");
        stopped = true;
        intents = null;
        current = null;
    }
}
