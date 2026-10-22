/// Public facade for the Autonom daemon domain, configuration, interop, and policy modules.
module daemon;

public import daemon.agent : Profile, ProfileStore;
public import daemon.config;
public import daemon.exception;
public import daemon.interop;
public import daemon.policy;
