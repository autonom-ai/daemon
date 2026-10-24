module tests.db.profiles;

import daemon.db : Connection;
import daemon.db.profiles : Profiles, StoredProfile;
import daemon.exception : ConflictException;
import daemon.interop.session : SessionKey;
import tests.common : Fixture;

import arsd.sqlite : Sqlite;
import unit_threaded : Name, should, shouldThrow;

@Name("SQL profiles retain provider-qualified history without restoring liveness")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();
    Profiles profiles = new Profiles(connection);
    profiles.create("wren");
    profiles.create("marlow");
    profiles.list()[0].name.should == "marlow";
    profiles.get("missing").isNull.should == true;
    profiles.get("marlow").get.current.isNull.should == true;
    profiles.bind("marlow", SessionKey("devin", "first"));
    profiles.bind("marlow", SessionKey("devin", "second"));
    profiles.bind("wren", SessionKey("other", "first"));
    profiles.history("marlow").length.should == 2;
    profiles.bind("wren", SessionKey("devin", "first")).shouldThrow!ConflictException();
    profiles.get("wren").get.current.get.provider.should == "other";
    profiles.get("marlow").get.current.get.id.should == "second";
    profiles.bind("missing", SessionKey("devin", "unknown")).shouldThrow!Exception();
    profiles.create("human").shouldThrow!Exception();
    profiles.create("MARLOW").shouldThrow!Exception();
    profiles.create("marlow").shouldThrow!Exception();
    profiles.history("missing").length.should == 0;
    connection.close();

    connection = new Connection(fixture.config.dataDir);
    profiles = new Profiles(connection);
    StoredProfile snapshot = profiles.get("marlow").get;
    profiles.unbind("marlow");
    snapshot.current.get.id.should == "second";
    profiles.get("marlow").get.current.isNull.should == true;
    profiles.history("marlow").length.should == 2;
    static assert(!__traits(compiles, snapshot.online));
    static assert(!__traits(compiles, snapshot.token));
}

@Name("SQL profile creation rolls back when its binding cannot be persisted")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    Connection connection = new Connection(fixture.config.dataDir);
    scope(exit)
        connection.close();

    Sqlite fault = new Sqlite(connection.path);
    fault.query("create trigger fail_binding before insert on profile_bindings "~
        "begin select raise(abort, 'fixture failure'); end");
    destroy(fault);
    Profiles profiles = new Profiles(connection);
    profiles.create("partial").shouldThrow!Exception();
    profiles.list().length.should == 0;
    fault = new Sqlite(connection.path);
    fault.query("drop trigger fail_binding");
    destroy(fault);
    profiles.create("partial");
    profiles.list().length.should == 1;
}

@Name("Provider-qualified session keys own input buffers and reject invalid identities")
unittest
{
    char[] provider = "devin".dup;
    char[] id = "session-one".dup;
    SessionKey key = SessionKey(cast(string)provider, cast(string)id);
    provider[] = 'x';
    id[] = 'x';
    key.provider.should == "devin";
    key.id.should == "session-one";
    SessionKey.init.validate().shouldThrow!Exception();
    SessionKey("Devin", "session").shouldThrow!Exception();
    SessionKey("devin", "bad id").shouldThrow!Exception();
}
