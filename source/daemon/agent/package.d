/// Durable agent profiles and session-assignment registry.
module daemon.agent;

public import daemon.agent.profile : humanName, Profile;
public import daemon.agent.store : ProfileConflictException, ProfileStore, validName;
