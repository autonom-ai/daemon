module autonom.app;

import autonom.agent.profile;
import autonom.agent.store;
import autonom.config;
import autonom.hooks;
import autonom.policy.access;
import autonom.server;
import autonom.interop.cleanup;
import autonom.interop.devin.bridge;
import autonom.interop.session;
import serverino;

mixin ServerinoMain!(
    autonom.agent.profile,
    autonom.agent.store,
    autonom.config,
    autonom.hooks,
    autonom.policy.access,
    autonom.server,
    autonom.interop.cleanup,
    autonom.interop.devin.bridge,
    autonom.interop.session
);
