module autonom.policy.access;

import autonom.policy.format : PolicyAction, PolicyResult, PolicyRule, loadRules;
import autonom.server : policy, readBody, respond;
import intuit.response.decision : Decision, DecisionQuestion, DecisionType;
import intuit.router : IRouter, decisions;
import serverino : Output, Request, endpoint, route;

import core.time : MonoTime, seconds;
import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.file : isDir;
import std.json : JSONType, JSONValue;

class Policy
{
private:
    IRouter router;

    bool screen(PolicyRule rule, string tool, JSONValue input)
    {
        enum TIMEOUT = 8.seconds;
        MonoTime deadline = MonoTime.currTime + TIMEOUT;
        router.operationTimeout(TIMEOUT);
        if (router.active != model)
            router.active(model);

        enforce(MonoTime.currTime < deadline, "Policy request timed out");
        router.operationTimeout(deadline - MonoTime.currTime);
        JSONValue state = JSONValue.emptyObject;
        state["tool"] = JSONValue(tool);
        state["input"] = input;
        DecisionQuestion[] questions;
        foreach (configured; rule.questions)
        {
            DecisionQuestion question;
            question.type = DecisionType.Predicate;
            question.name = configured.name;
            question.instructions = configured.instructions;
            questions ~= question;
        }

        Decision decision = decisions(router, state, questions);
        foreach (answer; decision.answers)
        {
            enforce(answer.type == DecisionType.Predicate, "Policy model returned no predicate decision");
            if (answer.probability >= rule.threshold)
                return true;
        }

        return false;
    }

public:
    const string model;

    this(IRouter router, string model)
    {
        enforce(router !is null && model.length && !model.canFind('\0'), "A policy router and model are required");
        this.router = router;
        this.model = model;
        router.connectTimeout(2.seconds);
    }

    PolicyResult check(string directory, string tool, JSONValue input = JSONValue.emptyObject)
    {
        router.context.clear();
        scope(exit)
            router.context.clear();

        enforce(directory.length && isDir(directory), "An existing working directory is required");
        enforce(tool.length && !tool.canFind('\0'), "A tool name is required");
        enforce(input.type == JSONType.object, "Tool input must be an object");
        foreach (rule; loadRules(directory))
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

@endpoint @route!"/api/policy/check"
void checkPolicy(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    JSONValue data = readBody(request);
    enforce("directory" in data.object && "tool" in data.object, "Expected directory and tool");
    enforce(data["directory"].type == JSONType.string && data["tool"].type == JSONType.string,
        "Directory and tool must be strings");
    foreach (name; data.object.keys)
        enforce(name == "directory" || name == "tool" || name == "input", "Unexpected policy request field");

    if ("input" !in data.object)
        data["input"] = JSONValue.emptyObject;

    enforce(data["input"].type == JSONType.object, "Tool input must be an object");
    try
        respond(output, policy.check(data["directory"].str, data["tool"].str, data["input"]).toJSON());
    catch (Exception)
        respond(output, PolicyResult(true, "Policy check failed").toJSON(), 503);
}
