module tests.config;

import autonom.config;
import intuit.router.openrouter;
import tests.common;
import unit_threaded : Name, should, shouldThrow;

import core.time : hours, minutes, seconds;
import std.file : exists, symlink, write;
import std.path : buildPath;

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

@Name("Config defaults only the data and lock directories")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "defaults.yml");
    write(path, "devinCommand: devin\n"~ROUTER);
    Config config = new Config(path);
    config.dataDir.should == fixture.root;
    config.sessionLockDir.should == Config.defaultSessionLockDir;
    config.devinCommand.should == "devin";
}

@Name("Config builds its configured OpenRouter")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    write(fixture.path, `devinCommand: devin
router:
  type: openrouter
  key: test-key
  url: https://router.example
  name: autonom-test
  referer: https://example.test
  title: Autonom Test
`);
    Config config = new Config(fixture.path);
    OpenRouter router = cast(OpenRouter)config.router;
    (router !is null).should == true;
    router.name.should == "autonom-test";
    router.referer.should == "https://example.test";
    router.title.should == "Autonom Test";
}

@Name("Config requires an existing file, devinCommand, and router")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string missingDirectory = buildPath(fixture.root, "missing");
    (new Config(buildPath(missingDirectory, "config.yml"))).shouldThrow!Exception();
    exists(missingDirectory).should == false;

    foreach (content; [
        "devinCommand: devin\n",
        ROUTER
    ])
    {
        write(fixture.path, content);
        (new Config(fixture.path)).shouldThrow!Exception();
    }
}

@Name("Config rejects malformed YAML and unsupported settings")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string complete = "devinCommand: devin\n"~ROUTER;
    foreach (content; [
        "dataDir: [\n",
        "[]\n",
        "unknown: test\n",
        "policyUrl: http://127.0.0.1:1234\n",
        "policyModel: test-model\n",
        "dataDir: 42\n",
        "dataDir: ''\n",
        "dataDir: null\n"
    ])
    {
        write(fixture.path, content~complete);
        (new Config(fixture.path)).shouldThrow!Exception();
    }
}

@Name("Config rejects incomplete and unsupported routers")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    foreach (router; [
        "router: []\n",
        "router: {}\n",
        "router:\n  type: unsupported\n  key: test-key\n  url: https://openrouter.ai\n  name: OpenRouter\n",
        "router:\n  type: openrouter\n  url: https://openrouter.ai\n  name: OpenRouter\n",
        "router:\n  type: openrouter\n  key: ''\n  url: https://openrouter.ai\n  name: OpenRouter\n",
        "router:\n  type: openrouter\n  key: test-key\n  url: ftp://openrouter.ai\n  name: OpenRouter\n",
        "router:\n  type: openrouter\n  key: test-key\n  url: https://openrouter.ai\n"
    ])
    {
        write(fixture.path, "devinCommand: devin\n"~router);
        (new Config(fixture.path)).shouldThrow!Exception();
    }
}

@Name("Config parses wake settings and durations")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    fixture.config.compactOnResume.should == false;
    fixture.config.offlineStartAfter.should == 1.hours;
    fixture.config.offlineCompactAfter.should == 1.hours;
    fixture.config.sessionDatabase.should == buildPath(fixture.root, "sessions.db");

    write(fixture.path, "devinCommand: devin\ncompactOnResume: true\nofflineStartAfter: 30m\nofflineCompactAfter: 90\n"~ROUTER);
    Config config = new Config(fixture.path);
    config.compactOnResume.should == true;
    config.offlineStartAfter.should == 30.minutes;
    config.offlineCompactAfter.should == 90.seconds;

    foreach (content; [
        `compactOnResume: "yes"`~"\n",
        "compactOnResume: 1\n",
        "offlineStartAfter: soon\n",
        "offlineStartAfter: 0s\n",
        "offlineStartAfter: -5\n",
        "offlineCompactAfter: []\n"
    ])
    {
        write(fixture.path, "devinCommand: devin\n"~content~ROUTER);
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
