module tests.interop.devin.hooks;

import daemon.interop.devin.hooks : installHooks;
import tests.common : Fixture;

import unit_threaded : Name, should, shouldThrow;

import std.file : getcwd, readText, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;

@Name("Global hooks repair stale Autonom commands and preserve user commands and configuration")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "devin.json");
    write(path, `{
        "model": "swe-2-medium",
        "hooks": {
            "PreToolUse": [{"matcher": "exec", "custom": 7, "hooks": [
                {"type": "command", "command": "python3 /moved/source/coord/hook.py"},
                {"type": "command", "command": "python3 /user/hook.py"}
            ]}]
        }
    }`);
    installHooks(getcwd(), path);
    JSONValue config = parseJSON(readText(path));
    config["model"].str.should == "swe-2-medium";
    JSONValue entries = config["hooks"]["PreToolUse"];
    entries.array.length.should == 2;
    entries[0]["custom"].integer.should == 7;
    entries[0]["matcher"].str.should == "exec";
    entries[0]["hooks"].array.length.should == 1;
    entries[0]["hooks"][0]["command"].str.should == "python3 /user/hook.py";
    entries[1]["hooks"][0]["command"].str.should ==
        "python3 \""~getcwd()~"/source/daemon/interop/devin/hook.py\" --event PreToolUse";

    string installed = readText(path);
    installHooks(getcwd(), path);
    readText(path).should == installed;
    config["hooks"].object.length.should == 8;
}

@Name("Global hook registration refuses malformed user configuration without replacing it")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "devin.json");
    foreach (content; ["{", `{"hooks":[]}`, `{"hooks":{"PreToolUse":[{}]}}`])
    {
        write(path, content);
        installHooks(getcwd(), path).shouldThrow!Exception();
        readText(path).should == content;
    }
}
