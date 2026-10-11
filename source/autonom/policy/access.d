module autonom.policy.access;

import autonom.config;
import autonom.exception;
import autonom.policy.rule;
import autonom.server : policy, readBody, respond;
import intuit.response.decision;
import intuit.router : IRouter, decisions;
import serverino;

import core.time : MonoTime, seconds;
import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.file;
import std.json : JSONType, JSONValue;

public:

@endpoint @route!"/api/policy/check"
void checkPolicy(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    JSONValue data = readBody(request);
    enforce!InvalidInputException("directory" in data.object && "tool" in data.object,
        "Expected directory and tool");
    enforce!InvalidInputException(data["directory"].type == JSONType.string && data["tool"].type == JSONType.string,
        "Directory and tool must be strings");
    foreach (name; data.object.keys)
    {
        enforce!InvalidInputException(name == "directory" || name == "tool" || name == "input",
            "Unexpected policy request field");
    }

    if ("input" !in data.object)
        data["input"] = JSONValue.emptyObject;

    enforce!InvalidInputException(data["input"].type == JSONType.object, "Tool input must be an object");
    try
        respond(output, policy.check(data["directory"].str, data["tool"].str, data["input"]).toJSON());
    catch (Exception)
        respond(output, PolicyResult(true, "Policy check failed").toJSON(), 503);
}

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

class Policy
{
private:
    Config config;

    bool screen(PolicyRule rule, string tool, JSONValue input)
    {
        enum TIMEOUT = 8.seconds;
        MonoTime deadline = MonoTime.currTime + TIMEOUT;
        JSONValue state = JSONValue.emptyObject;
        state["tool"] = JSONValue(tool);
        state["input"] = input;

        foreach (i, model; rule.models)
        {
            enforce!InvalidInputException(MonoTime.currTime < deadline, "Policy request timed out");
            IRouter router = config.router;
            router.operationTimeout(deadline - MonoTime.currTime);
            router.context.clear();

            try
            {
                if (router.active != model)
                    router.active(model);

                Decision decision = decisions(router, state, rule.questions);
                foreach (answer; decision.answers)
                {
                    enforce!InvalidInputException(answer.type == DecisionType.Predicate,
                        "Policy model returned no predicate decision");
                    if (answer.probability >= rule.threshold)
                        return true;
                }

                return false;
            }
            catch (Exception error)
            {
                if (i + 1 == rule.models.length)
                    throw error;
            }
        }

        assert(0);
    }

public:
    this(Config configuration)
    {
        enforce!InvalidInputException(configuration !is null && configuration.router !is null,
            "A policy configuration and router are required");
        this.config = configuration;
        configuration.router.connectTimeout(2.seconds);
    }

    PolicyResult check(string directory, string tool, JSONValue input = JSONValue.emptyObject)
    {
        config.router.context.clear();
        scope(exit)
            config.router.context.clear();

        enforce!InvalidInputException(directory.length && isDir(directory),
            "An existing working directory is required");
        enforce!InvalidInputException(tool.length && !tool.canFind('\0'), "A tool name is required");
        enforce!InvalidInputException(input.type == JSONType.object, "Tool input must be an object");
        PolicyFile policyFile = PolicyFile.loadRules(directory);
        foreach (rule; policyFile.rules)
        {
            if (!rule.matches(tool, input))
                continue;

            final switch (rule.action)
            {
            case PolicyAction.Allow:
                return PolicyResult(false);

            case PolicyAction.Screen:
                if (!screen(rule, tool, input))
                    return PolicyResult(false);

                goto case PolicyAction.Deny;

            case PolicyAction.Deny:
                return PolicyResult(true, rule.reason.length ? rule.reason : "Denied by workspace policy");
            }
        }

        return PolicyResult(true, "No policy rule matched");
    }
}
