module daemon.app;

import daemon.agent.profile;
import daemon.agent.store;
import daemon.api;
import daemon.coord.api;
import daemon.events.event;
import daemon.events.schedule;
import daemon.hooks;
import daemon.interop.api;
import daemon.interop.mcp;
import daemon.policy.access;
import serverino;

mixin ServerinoMain!(
    daemon.agent.profile,
    daemon.agent.store,
    daemon.coord.api,
    daemon.events.event,
    daemon.events.schedule,
    daemon.hooks,
    daemon.policy.access,
    daemon.api,
    daemon.interop.api,
    daemon.interop.mcp
);
