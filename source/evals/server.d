module evals.server;

version (AutonomHttpTest)
{
    import autonom : Api, Config, Devin, ProfileStore;
    import serverino;

    import std.process : environment;

    Api api;

    mixin ServerinoMain;

    @onServerInit ServerinoConfig setup()
    {
        return ServerinoConfig.create().addListener("127.0.0.1", 18080).setWorkers(2);
    }

    @onWorkerStart void setupWorker()
    {
        Config config = new Config(environment.get("AUTONOM_TEST_CONFIG"));
        api = new Api(config, new ProfileStore(config, new Devin(config)), "/api");
    }

    @endpoint void handle(Request request, Output output)
    {
        api.route(request, output);
    }
}
