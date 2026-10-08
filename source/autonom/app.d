module autonom.app;

import autonom.config;
import autonom.profilestore;
import autonom.policy;
import autonom.server;
import autonom.session.devin.bridge;
import autonom.session.session;
import serverino;

mixin ServerinoMain!(
    autonom.config,
    autonom.profilestore,
    autonom.policy,
    autonom.server,
    autonom.session.devin.bridge,
    autonom.session.session
);
