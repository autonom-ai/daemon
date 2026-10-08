module autonom.policy.policy;

import autonom.policy.document : PolicyDocument;
import autonom.policy.input : scrub;
import autonom.policy.result : PolicyResult;
import autonom.policy.rule : PolicyAction, PolicyRule;
import intuit.response.decision : Decision, DecisionQuestion, DecisionType;
import intuit.router : IRouter, decisions;

import core.time : MonoTime, seconds;
import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.file : isDir;
import std.json : JSONType, JSONValue;

public:

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
        state["input"] = scrub(input, rule.expose);
        if (rule.context.length)
            state["context"] = JSONValue(rule.context);

        DecisionQuestion question;
        question.name = "harmful";
        question.instructions = rule.question;
        Decision decision = decisions(router, state, [question]);
        enforce(decision.answer.type == DecisionType.Predicate, "Policy model returned no decision");
        return decision.answer.probability >= rule.threshold;
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
        PolicyDocument document = PolicyDocument.load(directory);
        foreach (rule; document.rules)
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
