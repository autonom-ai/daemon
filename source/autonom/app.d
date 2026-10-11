module autonom.app;

import autonom.agent.profile;
import autonom.agent.store;
import autonom.config;
import autonom.coord.access;
import autonom.hooks;
import autonom.policy.access;
import autonom.server;
import autonom.interop.devin.bridge;
import autonom.interop.execution;
import autonom.interop.session;
import serverino;

mixin ServerinoMain!(
    autonom.agent.profile,
    autonom.agent.store,
    autonom.config,
    autonom.coord.access,
    autonom.hooks,
    autonom.policy.access,
    autonom.server,
    autonom.interop.devin.bridge,
    autonom.interop.execution,
    autonom.interop.session
);
