module daemon.policy.access;

import daemon.config;
import daemon.exception;
import daemon.policy.rule;
import daemon.http : acceptMethod, onlyFields, readBody, respond, respondError;
import daemon.api : policy;
import intuit.response.decision;
import intuit.router : IRouter, decisions;
import serverino;

import core.time : MonoTime, seconds;
import std.algorithm.searching : canFind;
import std.file : isDir;
import std.json : JSONType, JSONValue;

public:

@endpoint @route!"/api/policy"
void inspectPolicy(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    try
        respond(output, policy.inspect(request.get.read("directory")));
    catch (Exception error)
        respondError(output, 503, "Could not load workspace policy: "~error.msg);
}

@endpoint @route!"/api/policy/check"
void checkPolicy(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readBody(request);
    onlyFields(data, ["directory", "tool", "input"]);
    if ("directory" !in data.object || "tool" !in data.object)
        throw new InvalidInputException("Expected directory and tool");

    if (data["directory"].type != JSONType.string || data["tool"].type != JSONType.string)
        throw new InvalidInputException("Directory and tool must be strings");

    if ("input" !in data.object)
        data["input"] = JSONValue.emptyObject;

    if (data["input"].type != JSONType.object)
        throw new InvalidInputException("Tool input must be an object");

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
            if (MonoTime.currTime >= deadline)
                throw new InvalidInputException("Policy request timed out");

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
                    if (answer.type != DecisionType.Predicate)
                        throw new InvalidInputException("Policy model returned no predicate decision");
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
        if (configuration is null || configuration.router is null)
            throw new InvalidInputException("A policy configuration and router are required");

        this.config = configuration;
        configuration.router.connectTimeout(2.seconds);
    }

    JSONValue inspect(string directory)
    {
        if (!directory.length || !isDir(directory))
            throw new InvalidInputException("An existing working directory is required");

        PolicyFile file = PolicyFile.loadRules(directory);
        JSONValue ret = JSONValue.emptyArray;
        foreach (rule; file.rules)
        {
            JSONValue entry = JSONValue([
                "action": JSONValue(cast(string)rule.action),
                "match": JSONValue(rule.match),
                "reason": rule.reason.length ? JSONValue(rule.reason) : JSONValue(null),
                "models": JSONValue(rule.models),
                "threshold": JSONValue(rule.threshold),
                "questions": JSONValue.emptyArray
            ]);
            foreach (question; rule.questions)
                entry["questions"].array ~= JSONValue([
                    "type": JSONValue("predicate"),
                    "name": JSONValue(question.name),
                    "instructions": JSONValue(question.instructions)
                ]);

            ret.array ~= entry;
        }

        return ret;
    }

    PolicyResult check(string directory, string tool, JSONValue input = JSONValue.emptyObject)
    {
        config.router.context.clear();
        scope(exit)
            config.router.context.clear();

        if (!directory.length || !isDir(directory))
            throw new InvalidInputException("An existing working directory is required");

        if (!tool.length || tool.canFind('\0'))
            throw new InvalidInputException("A tool name is required");

        if (input.type != JSONType.object)
            throw new InvalidInputException("Tool input must be an object");

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
