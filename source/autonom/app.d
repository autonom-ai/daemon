module autonom.app;

import autonom.agent.profile;
import autonom.agent.store;
import autonom.coord.access;
import autonom.client;
import autonom.events.event;
import autonom.events.schedule;
import autonom.hooks;
import autonom.policy.access;
import autonom.server;
import autonom.interop.devin.bridge;
import autonom.interop.execution;
import autonom.interop.permission;
import autonom.interop.session;
import serverino;

mixin ServerinoMain!(
    autonom.agent.profile,
    autonom.agent.store,
    autonom.coord.access,
    autonom.client,
    autonom.events.event,
    autonom.events.schedule,
    autonom.hooks,
    autonom.policy.access,
    autonom.server,
    autonom.interop.devin.bridge,
    autonom.interop.execution,
    autonom.interop.permission,
    autonom.interop.session
);
