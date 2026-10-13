module daemon.policy.rule;

import daemon.storage;
import intuit.response.decision;
import mir.algebraic_alias.yaml;
import mir.deser.yaml;

import std.algorithm.searching : canFind;
import std.json : JSONType, JSONValue;
import std.math.traits : isFinite;
import std.path : buildPath;
import std.regex : Regex, matchFirst, regex;
import std.string : strip;

package(daemon.policy):

enum PolicyAction : string
{
    Deny = "deny",
    Allow = "allow",
    Screen = "screen"
}

struct PolicyFile
{
    PolicyRule[] rules;

    static PolicyFile loadRules(string directory)
    {
        string path = buildPath(directory, ".devin", "policy.yml");
        YamlAlgebraic document = readText(path).deserializeYaml!YamlAlgebraic(path);
        if (document.kind != YamlAlgebraic.Kind.object)
            throw new Exception("Policy must be a mapping");

        string stringValue(YamlAlgebraic value, string field)
        {
            if (value.kind != YamlAlgebraic.Kind.string)
                throw new Exception(field~" must be a string");

            return value.get!string.idup;
        }

        YamlAlgebraic required(YamlMap mapping, string field, string context)
        {
            if (field !in mapping)
                throw new Exception(context~" requires "~field);

            return mapping[field];
        }

        void onlyFields(YamlMap mapping, string[] fields, string context)
        {
            bool[string] seen;
            foreach (pair; mapping.pairs)
            {
                string field = stringValue(pair.key, context~" field name");
                if (!fields.canFind(field))
                    throw new Exception("Unknown "~context~" field: "~field);
                if (field in seen)
                    throw new Exception("Duplicate "~context~" field: "~field);

                seen[field] = true;
            }
        }

        DecisionQuestion readQuestion(YamlAlgebraic value)
        {
            if (value.kind != YamlAlgebraic.Kind.object)
                throw new Exception("Screen questions must be mappings");

            onlyFields(value.object, ["type", "name", "instructions"], "screen question");
            if (stringValue(required(value.object, "type", "Screen question"), "Question type") != "predicate")
                throw new Exception("Screen questions must use predicate types");

            DecisionQuestion ret;
            ret.type = DecisionType.Predicate;
            ret.name = stringValue(required(value.object, "name", "Screen question"), "Question name");
            ret.instructions = stringValue(
                required(value.object, "instructions", "Screen question"),
                "Question instructions"
            );
            return ret;
        }

        PolicyRule readRule(YamlAlgebraic value)
        {
            if (value.kind != YamlAlgebraic.Kind.object)
                throw new Exception("Policy rules must be mappings");

            onlyFields(
                value.object,
                ["action", "match", "reason", "questions", "models", "threshold"],
                "policy rule"
            );
            string action = stringValue(required(value.object, "action", "Policy rule"), "Policy action");
            PolicyRule ret;
            switch (action)
            {
            case "allow":
                ret.action = PolicyAction.Allow;
                break;

            case "deny":
                ret.action = PolicyAction.Deny;
                break;

            case "screen":
                ret.action = PolicyAction.Screen;
                break;
            default:
                throw new Exception("Unknown policy action: "~action);
            }

            if ("match" in value.object && !value.object["match"].isNull)
            {
                YamlAlgebraic matches = value.object["match"];
                if (matches.kind != YamlAlgebraic.Kind.object)
                    throw new Exception("Policy match must be a mapping");

                foreach (pair; matches.object.pairs)
                {
                    string field = stringValue(pair.key, "Policy match field name");
                    if (field in ret.match)
                        throw new Exception("Duplicate policy match field: "~field);

                    ret.match[field] = stringValue(pair.value, "Policy match pattern");
                }
            }

            if ("reason" in value.object && !value.object["reason"].isNull)
                ret.reason = stringValue(value.object["reason"], "Policy reason");

            if ("questions" in value.object && !value.object["questions"].isNull)
            {
                YamlAlgebraic questions = value.object["questions"];
                if (questions.kind != YamlAlgebraic.Kind.array)
                    throw new Exception("Screen questions must be a list");

                foreach (YamlAlgebraic question; questions.array)
                    ret.questions ~= readQuestion(question);
            }

            if ("models" in value.object)
            {
                YamlAlgebraic models = value.object["models"];
                if (models.kind != YamlAlgebraic.Kind.array)
                    throw new Exception("Screen models must be a list");

                ret.models = new string[0];
                foreach (YamlAlgebraic model; models.array)
                    ret.models ~= stringValue(model, "Screen model identifier");
            }

            if ("threshold" in value.object && !value.object["threshold"].isNull)
            {
                YamlAlgebraic threshold = value.object["threshold"];
                if (threshold.kind == YamlAlgebraic.Kind.integer)
                    ret.threshold = cast(double)threshold.get!long;
                else if (threshold.kind == YamlAlgebraic.Kind.float_)
                    ret.threshold = threshold.get!double;
                else
                    throw new Exception("Policy threshold must be a number");
            }

            ret.compile();
            return ret;
        }

        onlyFields(document.object, ["rules"], "policy file");
        YamlAlgebraic rules = required(document.object, "rules", "Policy file");
        if (rules.kind != YamlAlgebraic.Kind.array)
            throw new Exception("Policy rules must be a list");

        PolicyFile ret;
        foreach (YamlAlgebraic rule; rules.array)
            ret.rules ~= readRule(rule);

        return ret;
    }
}

struct PolicyRule
{
private:
    Regex!char[string] patterns;

public:
    PolicyAction action;
    string[string] match;
    string reason;
    DecisionQuestion[] questions;
    string[] models;
    double threshold = 0.5;

    void compile()
    {
        if (!threshold.isFinite || threshold < 0 || threshold > 1)
            throw new Exception("Invalid policy threshold");

        if (action == PolicyAction.Screen && !questions.length)
            throw new Exception("A screen rule requires questions");

        foreach (field, pattern; match)
        {
            if (!field.length || field.canFind('\0'))
                throw new Exception("Invalid policy match field");

            patterns[field] = regex(pattern);
        }

        if (action == PolicyAction.Screen)
        {
            if (!models.length)
                throw new Exception("A screen rule requires models");

            bool[string] seenModels;
            foreach (model; models)
            {
                if (!model.length || model.canFind('\0'))
                    throw new Exception("Invalid screening model identifier");

                if (model in seenModels)
                    throw new Exception("Screening models must be unique");

                seenModels[model] = true;
            }

            bool[string] names;
            foreach (ref question; questions)
            {
                question.instructions = question.instructions.strip;
                if (question.type != DecisionType.Predicate || !question.name.strip.length ||
                    question.name.canFind('\0') || !question.instructions.length)
                    throw new Exception("Screen questions require predicate types, names, and instructions");

                if (question.name in names)
                    throw new Exception("Screen question names must be unique");

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
