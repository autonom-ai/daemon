module daemon.app;

import daemon.agent.profile;
import daemon.agent.store;
import daemon.coord.access;
import daemon.client;
import daemon.events.event;
import daemon.events.schedule;
import daemon.hooks;
import daemon.policy.access;
import daemon.server;
import daemon.interop.api;
import daemon.interop.mcp;
import serverino;

mixin ServerinoMain!(
    daemon.agent.profile,
    daemon.agent.store,
    daemon.coord.access,
    daemon.client,
    daemon.events.event,
    daemon.events.schedule,
    daemon.hooks,
    daemon.policy.access,
    daemon.server,
    daemon.interop.api,
    daemon.interop.mcp
);
