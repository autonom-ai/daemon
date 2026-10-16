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
import daemon.interop.devin.bridge;
import daemon.interop.execution;
import daemon.interop.mcp;
import daemon.interop.permission;
import daemon.interop.session;
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
    daemon.interop.devin.bridge,
    daemon.interop.execution,
    daemon.interop.mcp,
    daemon.interop.permission,
    daemon.interop.session
);
