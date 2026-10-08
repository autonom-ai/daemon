module autonom.policy.result;

import std.json : JSONValue;

public:

struct PolicyResult
{
    bool denied;
    string reason;

    JSONValue toJSON() const
    {
        JSONValue ret = JSONValue.emptyObject;
        ret["denied"] = JSONValue(denied);
        ret["reason"] = reason.length ? JSONValue(reason) : JSONValue(null);
        return ret;
    }
}
