module tests.profilestore;

import autonom.profile : Profile;
import autonom.profilestore : ProfileStore, ProfileConflict, profiles, getProfile, profileSession;
import tests.common : Fixture;
import serverino : endpoint, route;
import unit_threaded : Name, should, shouldThrow;

import std.array : replicate;
import std.conv : octal;
import std.file : FileException, getAttributes, readText, remove, symlink, write;
import std.json : parseJSON;
import std.path : buildPath;
import std.traits : hasUDA;

@Name("ProfileStore declares module-level HTTP endpoints")
unittest
{
    static foreach (HANDLER; ["profiles", "getProfile", "profileSession"])
    {
        hasUDA!(mixin(HANDLER), endpoint).should == true;
        hasUDA!(mixin(HANDLER), route).should == true;
    }
}

@Name("ProfileStore creates canonical profile names without identity files")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile profile = fixture.store.create("Marlow");
    profile.name.should == "marlow";
    (profile.session is null).should == true;
    fixture.store.list().length.should == 1;
    fixture.store.create("MARLOW").shouldThrow!ProfileConflict();
}

@Name("ProfileStore registration persists across instances")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Profile profile = fixture.store.register("Marlow", "session-1");
    profile.session.id.should == "session-1";
    (fixture.store.get("MARLOW").session is profile.session).should == true;
    ProfileStore store = new ProfileStore(fixture.config, fixture.bridge);
    store.get("marlow").session.id.should == "session-1";
}

@Name("ProfileStore rejects invalid session IDs without corrupting the registry")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.register("marlow", "session-1");
    fixture.store.register("marlow", "../escape").shouldThrow!Exception();
    fixture.store.get("marlow").session.id.should == "session-1";
    fixture.store.register("wren", "invalid id").shouldThrow!Exception();
    (fixture.store.get("wren") is null).should == true;
}

@Name("ProfileStore replaces offline associations without retaining history")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.register("marlow", "session-1");
    fixture.store.register("marlow", "session-2");
    parseJSON(readText(buildPath(fixture.store.directory, "profiles.json")))["marlow"].str.should == "session-2";
    (fixture.store.get("wren") is null).should == true;
}

@Name("ProfileStore prevents duplicate session ownership")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.register("marlow", "session-1");
    fixture.store.register("wren", "session-1").shouldThrow!ProfileConflict();
    (fixture.store.get("wren") is null).should == true;
}

@Name("ProfileStore rejects names that can escape storage")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    foreach (name; [
        "",
        "../escape",
        "white space",
        "-name",
        "a".replicate(65)
    ])
        fixture.store.create(name).shouldThrow!Exception();

    fixture.store.list().length.should == 0;
}

@Name("ProfileStore does not overwrite corrupt registry data")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.store.directory, "profiles.json");
    foreach (content; [
        "{",
        "[]",
        `{"marlow":7}`,
        `{"../escape":null}`,
        `{"Marlow":null}`,
        `{"marlow":"session-1","wren":"session-1"}`
    ])
    {
        write(path, content);
        fixture.store.create("agent").shouldThrow!FileException();
        readText(path).should == content;
    }
}

@Name("ProfileStore rejects symlinked registry and keeps private permissions")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.store.create("marlow");
    string path = buildPath(fixture.store.directory, "profiles.json");
    (getAttributes(path) & octal!"777").should == octal!"600";
    string target = buildPath(fixture.root, "target.json");
    write(target, "{}");
    remove(path);
    symlink(target, path);
    fixture.store.list().shouldThrow!Exception();
    readText(target).should == "{}";
}
