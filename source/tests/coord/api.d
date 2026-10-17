module tests.coord.api;

import daemon.coord.messages;
import daemon.coord.rooms;

import serverino : endpoint, route;
import unit_threaded : Name, should;

import std.traits : hasUDA;

@Name("Coordination declares module-level HTTP endpoints")
unittest
{
    static foreach (handler; ["rooms", "room", "roomMessages", "roomMembership", "roomAdmins", "messages"])
    {
        hasUDA!(mixin(handler), endpoint).should == true;
        hasUDA!(mixin(handler), route).should == true;
    }
}
