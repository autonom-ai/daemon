module tests.events.metadata;

import daemon.interop.devin.session.catalog : sessionMetadata;
import daemon.interop.metadata : SessionMetadata;
import tests.common : Fixture;
import tests.events.common : writeSessionDatabase;

import unit_threaded : Name, should;

import std.conv : to;

@Name("Session metadata falls back to the CLI database")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.bridge.sessionMetadata("session-1").model.length.should == 0;
    writeSessionDatabase(fixture.config.sessionDatabase, "session-1", "SWE-2", fixture.root);
    SessionMetadata metadata = fixture.bridge.sessionMetadata("session-1");
    metadata.model.should == "SWE-2";
    metadata.directory.should == fixture.root;
    fixture.bridge.sessionMetadata("missing").directory.length.should == 0;
}
