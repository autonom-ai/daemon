module tests.permission;

import daemon.interop.permission;
import unit_threaded : Name, should, shouldThrow;

import std.json : JSONValue;

@Name("Permission requests require a single explicit human decision")
unittest
{
    PermissionStore store = new PermissionStore();
    Permission request = store.add("managed-one", "exec", JSONValue(["command": JSONValue("ls")]));
    store.pending().array.length.should == 1;
    request.toJSON()["decision"].str.should == "";
    request.decide("approve");
    request.toJSON()["decision"].str.should == "approve";
    request.decide("block").shouldThrow!Exception();
    store.pending().array.length.should == 0;
    store.get(request.id).session.should == "managed-one";
    store.remove(request.id);
    (store.get(request.id) is null).should == true;
}

@Name("Permission input is owned independently of reused hook payloads")
unittest
{
    JSONValue input = JSONValue(["command": JSONValue("safe command")]);
    Permission request = new Permission("managed-one", "exec", input);
    input["command"] = JSONValue("different command");
    request.input["command"].str.should == "safe command";
    request.decide("unsupported").shouldThrow!Exception();
    request.decision.length.should == 0;
}
