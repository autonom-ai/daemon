module autonom.policy.format;

import autonom.storage : openFile;
import mir.deser.yaml : deserializeYaml;
import mir.serde : serdeIgnore, serdeKeys, serdeOptional;

import core.sys.posix.fcntl : O_RDONLY;
import std.algorithm.searching : canFind;
import std.array : join;
import std.exception : enforce;
import std.json : JSONType, JSONValue;
import std.math.traits : isFinite;
import std.path : buildPath;
import std.regex : Regex, matchFirst, regex;
import std.stdio : File;
import std.string : strip;

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

private:

package(autonom.policy):

enum PolicyAction : string
{
    @serdeKeys("deny") Deny = "deny",
    @serdeKeys("allow") Allow = "allow",
    @serdeKeys("screen") Screen = "screen"
}

struct PolicyQuestion
{
    string type;
    string name;
    string instructions;
}

struct PolicyRule
{
private:
    @serdeIgnore Regex!char[string] patterns;

public:
    PolicyAction action;
    @serdeOptional string[string] match;
    @serdeOptional string reason;
    @serdeOptional PolicyQuestion[] questions;
    @serdeOptional double threshold = 0.5;

    void compile()
    {
        enforce(threshold.isFinite && threshold >= 0 && threshold <= 1, "Invalid policy threshold");
        enforce(action != PolicyAction.Screen || questions.length > 0, "A screen rule requires questions");
        foreach (field, pattern; match)
        {
            enforce(field.length && !field.canFind('\0'), "Invalid policy match field");
            patterns[field] = regex(pattern);
        }

        if (action == PolicyAction.Screen)
        {
            bool[string] names;
            foreach (ref question; questions)
            {
                question.instructions = question.instructions.strip;
                enforce(question.type == "predicate" && question.name.strip.length
                    && !question.name.canFind('\0') && question.instructions.length,
                    "Screen questions require predicate types, names, and instructions");
                enforce(question.name !in names, "Screen question names must be unique");
                names[question.name] = true;
            }
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

struct PolicyFile
{
    PolicyRule[] rules;
}

PolicyRule[] loadRules(string directory)
{
    enum MAX_SIZE = 64 * 1024;
    File file = openFile(buildPath(directory, ".devin", "policy.yml"), O_RDONLY);
    scope(exit)
        file.close();

    enforce(file.size <= MAX_SIZE, "Workspace policy is too large");
    string content = cast(string)file.byChunk(4096).join;
    enforce(content.length <= MAX_SIZE, "Workspace policy is too large");
    PolicyFile ret = deserializeYaml!PolicyFile(content);
    foreach (ref rule; ret.rules)
        rule.compile();

    return ret.rules;
}


