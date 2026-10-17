module tests.interop.mcp;

import daemon.interop.mcp;

import unit_threaded;

import std.json : JSONValue, parseJSON;

@Name("injectCoord replaces a stale entry and preserves other servers")
unittest
{
    JSONValue params = parseJSON(`{"cwd":"/x","mcpServers":[{"name":"other","command":"x"},`~
        `{"name":"autonom-coord","command":"stale","env":[]}]}`);
    JSONValue injected = injectCoord(params, "18080", "token-value");
    JSONValue[] servers = injected["mcpServers"].array;
    servers.length.should == 2;
    servers[0]["name"].str.should == "other";
    servers[1]["name"].str.should == mcpServerName;
    string[string] env;
    foreach (entry; servers[1]["env"].array)
        env[entry["name"].str] = entry["value"].str;
    env["AUTONOM_PORT"].should == "18080";
    env["AUTONOM_MCP_TOKEN"].should == "token-value";
    env["AUTONOM_RUN_TOKEN"].should == "";
    env["AUTONOM_CLIENT_TOKEN"].should == "";
}
