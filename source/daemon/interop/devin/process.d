module daemon.interop.devin.process;

import std.process : environment;

/// Prevent inherited Desktop routing from redirecting the Devin CLI back into ACP.
string[string] cliEnvironment()
{
    string[string] ret = environment.toAA();
    ret.remove("ACP_BACKEND");
    return ret;
}
