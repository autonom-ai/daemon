module autonom.policy.rule;

import autonom.policy.input : isCredentialField;
import mir.serde : serdeIgnore, serdeKeys, serdeOptional;

import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.json : JSONType, JSONValue;
import std.math.traits : isFinite;
import std.regex : Regex, matchFirst, regex;
import std.string : strip, toLower;

public:

enum PolicyAction : string
{
    @serdeKeys("deny") Deny = "deny",
    @serdeKeys("allow") Allow = "allow",
    @serdeKeys("screen") Screen = "screen"
}

struct PolicyRule
{
private:
    @serdeIgnore Regex!char[string] patterns;

public:
    PolicyAction action;
    @serdeOptional string[string] match;
    @serdeOptional string reason;
    @serdeOptional string question;
    @serdeOptional string context;
    @serdeOptional string[] expose;
    @serdeOptional double threshold = 0.5;

    void compile()
    {
        enforce(threshold.isFinite && threshold >= 0 && threshold <= 1, "Invalid policy threshold");
        question = question.strip;
        enforce(action != PolicyAction.Screen || question.length, "A screen rule requires a question");
        foreach (field, pattern; match)
        {
            enforce(field.length && !field.canFind('\0'), "Invalid policy match field");
            patterns[field] = regex(pattern);
        }

        foreach (ref field; expose)
        {
            field = field.toLower;
            enforce(field.length && !field.isCredentialField,
                "Policy rules cannot expose credentials or session IDs");
        }
    }

    bool matches(string tool, JSONValue input)
    {
        foreach (field, pattern; patterns)
        {
            if (field == "tool")
            {
                if (tool.matchFirst(pattern).empty)
                    return false;
            }
            else
            {
                JSONValue* value = field in input.object;
                if (value is null || value.type != JSONType.string || value.str.matchFirst(pattern).empty)
                    return false;
            }
        }

        return true;
    }
}
