module tests.http.policy;

import tests.common;
import tests.http.common;

import unit_threaded;

import std.file : mkdirRecurse, write;
import std.json : JSONValue;
import std.path : buildPath;

@Name("Policy inspection loads current validated rules without screening a model") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    mkdirRecurse(buildPath(fixture.root, ".devin"));
    string path = buildPath(fixture.root, ".devin", "policy.yml");
    write(path, "rules:\n  - action: allow\n    match:\n      tool: ^read$\n    reason: Local reads\n");
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    JSONValue rules = request("/api/policy?directory="~fixture.root);
    rules.array.length.should == 1;
    rules[0]["action"].str.should == "allow";
    rules[0]["match"]["tool"].str.should == "^read$";
    rules[0]["reason"].str.should == "Local reads";
    write(path, "rules:\n  - action: deny\n");
    request("/api/policy?directory="~fixture.root)[0]["action"].str.should == "deny";
}

@Name("Policy inspection reports invalid rules and recovers after the file is fixed") @Serial
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();
    mkdirRecurse(buildPath(fixture.root, ".devin"));
    string path = buildPath(fixture.root, ".devin", "policy.yml");
    write(path, "rules:\n  - action: invalid\n");
    RunningDaemon daemon = startDaemon(fixture);
    scope(exit)
        daemon.close();

    request("/api/policy?directory="~fixture.root, 503);
    write(path, "rules: []\n");
    request("/api/policy?directory="~fixture.root).array.length.should == 0;
}
