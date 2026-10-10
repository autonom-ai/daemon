/// Workspace policy evaluation with optional model screening.
module autonom.policy.access;

import autonom.exception : InvalidInput;
import autonom.policy.rule : PolicyAction, PolicyRule, loadRules;
import autonom.server : policy, readBody, respond;
import intuit.response.decision : Decision, DecisionQuestion, DecisionType;
import intuit.router : IRouter, decisions;
import serverino : Output, Request, endpoint, route;

import core.time : MonoTime, seconds;
import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.file : isDir;
import std.json : JSONType, JSONValue;

public:

/// Checks a tool request, returning a denial with HTTP 503 when evaluation fails.
@endpoint @route!"/api/policy/check"
void checkPolicy(Request request, Output output)
{
    if (request.method != Request.Method.Post)
    {
        respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
        return;
    }

    JSONValue data = readBody(request);
    enforce!InvalidInput("directory" in data.object && "tool" in data.object, "Expected directory and tool");
    enforce!InvalidInput(data["directory"].type == JSONType.string && data["tool"].type == JSONType.string,
        "Directory and tool must be strings");
    foreach (name; data.object.keys)
        enforce!InvalidInput(name == "directory" || name == "tool" || name == "input", "Unexpected policy request field");

    if ("input" !in data.object)
        data["input"] = JSONValue.emptyObject;

    enforce!InvalidInput(data["input"].type == JSONType.object, "Tool input must be an object");
    try
        respond(output, policy.check(data["directory"].str, data["tool"].str, data["input"]).toJSON());
    catch (Exception)
        respond(output, PolicyResult(true, "Policy check failed").toJSON(), 503);
}

/// The outcome of a successfully evaluated workspace policy.
struct PolicyResult
{
    /// Whether the tool request is denied.
    bool denied;
    /// Explanation of a denial, or null when allowed.
    string reason;

    /// Serializes the result, representing an absent reason as JSON null.
    JSONValue toJSON() const
    {
        JSONValue ret = JSONValue.emptyObject;
        ret["denied"] = JSONValue(denied);
        ret["reason"] = reason.length ? JSONValue(reason) : JSONValue(null);
        return ret;
    }
}

/// Evaluates workspace rules using one shared router for screening.
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

        enforce!InvalidInput(MonoTime.currTime < deadline, "Policy request timed out");
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
            enforce!InvalidInput(answer.type == DecisionType.Predicate, "Policy model returned no predicate decision");
            if (answer.probability >= rule.threshold)
                return true;
        }

        return false;
    }

public:
    /// Model used for screen rules.
    const string model;

    /// Uses the supplied router and model, setting a two-second connection timeout.
    this(IRouter router, string model)
    {
        enforce!InvalidInput(router !is null && model.length && !model.canFind('\0'), "A policy router and model are required");
        this.router = router;
        this.model = model;
        router.connectTimeout(2.seconds);
    }

    /**
     * Reloads the workspace policy and evaluates its first matching rule.
     *
     * Unmatched requests are denied. Screening receives the input unchanged.
     * Router context is cleared before and after every check, including failures;
     * callers must serialize access to the shared router.
     *
     * Throws: Exception when the request or policy is invalid, or screening fails.
     */
    PolicyResult check(string directory, string tool, JSONValue input = JSONValue.emptyObject)
    {
        router.context.clear();
        scope(exit)
            router.context.clear();

        enforce!InvalidInput(directory.length && isDir(directory), "An existing working directory is required");
        enforce!InvalidInput(tool.length && !tool.canFind('\0'), "A tool name is required");
        enforce!InvalidInput(input.type == JSONType.object, "Tool input must be an object");
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
