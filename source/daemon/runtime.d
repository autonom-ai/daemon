module daemon.runtime;

import daemon.agent;
import daemon.config;
import daemon.coord;
import daemon.events;
import daemon.interop.bridge;
import daemon.policy;

import std.process : environment;

package(daemon):

Config configuration;
Bridge bridge;
ProfileStore profileStore;
Policy policy;
Bus bus;
EventStore events;
ScheduleStore scheduleStore;
Scheduler scheduler;

void setup()
{
    configuration = new Config(environment.get("AUTONOM_CONFIG", Config.defaultPath));
    bridge = new Bridge(configuration);
    profileStore = new ProfileStore(configuration, bridge);
    events = new EventStore(configuration, profileStore);
    bus = new Bus(configuration, profileStore);
    scheduleStore = new ScheduleStore(configuration, profileStore);
    scheduler = new Scheduler(configuration, bridge, profileStore, events, scheduleStore);
    policy = new Policy(configuration);
}

void close()
{
    if (scheduler !is null)
        scheduler.stop();
    if (bridge !is null)
        bridge.close();
}
