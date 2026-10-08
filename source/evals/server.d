module evals.server;

version (AutonomHttpTest)
{
    import autonom.config;
    import autonom.daemon.server;
    import autonom.profilestore;
    import serverino;

    mixin ServerinoMain!(autonom.daemon.server, autonom.config, autonom.profilestore);
}
