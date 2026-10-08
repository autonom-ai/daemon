module tests.config;

import autonom.config : Config, getConfig;
import tests.common : Fixture;
import serverino : endpoint, route;
import unit_threaded : Name, should, shouldThrow;

import std.file : exists, symlink, write;
import std.path : buildPath;
import std.traits : hasUDA;

@Name("Config declares its module-level HTTP endpoint")
unittest
{
    hasUDA!(getConfig, endpoint).should == true;
    hasUDA!(getConfig, route).should == true;
}

@Name("Config resolves paths relative to the YAML file")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.config.dataDir.should == buildPath(fixture.root, "data");
    fixture.config.sessionLockDir.should == buildPath(fixture.root, "locks");
    fixture.config.devinCommand.should == buildPath(fixture.root, "devin");
}

@Name("Config missing file uses defaults without creating storage")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Config config = new Config(buildPath(fixture.root, "missing", "config.yml"));
    config.dataDir.should == buildPath(fixture.root, "missing");
    config.devinCommand.should == "devin";
    exists(config.dataDir).should == false;
}

@Name("Config defaults to the free Mercury policy model without exposing credentials")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.config.toJSON()["policyUrl"].str.should == "https://openrouter.ai";
    fixture.config.toJSON()["policyModel"].str.should == "inception/mercury-decide:free";
    fixture.config.toJSON().object.length.should == 5;
}

@Name("Config accepts a policy router URL and model")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    write(fixture.path, "policyUrl: http://127.0.0.1:1234\npolicyModel: test-model\n");
    Config config = new Config(fixture.path);
    config.toJSON()["policyUrl"].str.should == "http://127.0.0.1:1234";
    config.toJSON()["policyModel"].str.should == "test-model";
}

@Name("Config rejects malformed YAML and unsupported settings")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    foreach (content; [
        "dataDir: [",
        "[]",
        "unknown: test",
        "dataDir: 42",
        "dataDir: ''"
    ])
    {
        write(fixture.path, content);
        (new Config(fixture.path)).shouldThrow!Exception();
    }
}

@Name("Config rejects symlinked configuration")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "linked.yml");
    symlink(fixture.path, path);
    (new Config(path)).shouldThrow!Exception();
}
