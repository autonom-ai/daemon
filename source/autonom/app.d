module autonom.app;

import autonom.config;
import autonom.profilestore;
import autonom.policy.endpoint;
import autonom.server;
import autonom.session.cleanup;
import autonom.session.devin.bridge;
import autonom.session.session;
import serverino;

mixin ServerinoMain!(
    autonom.config,
    autonom.profilestore,
    autonom.policy.endpoint,
    autonom.server,
    autonom.session.cleanup,
    autonom.session.devin.bridge,
    autonom.session.session
);
