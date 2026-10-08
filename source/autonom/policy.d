module autonom.policy;

import autonom.server : policy, readBody, respond;
import autonom.storage : openFile;
import intuit.response.decision : Decision, DecisionQuestion, DecisionType;
import intuit.router : IRouter, decisions;
import mir.deser.yaml : deserializeYaml;
import mir.serde : serdeIgnore, serdeKeys, serdeOptional;
import serverino : Output, Request, endpoint, route;

import core.sys.posix.fcntl : O_RDONLY;
import core.time : MonoTime, seconds;
import std.algorithm : canFind;
import std.array : join;
import std.exception : enforce;
import std.file : isDir;
import std.json : JSONType, JSONValue;
import std.math : isFinite;
import std.path : buildPath;
import std.regex : Regex, ctRegex, matchFirst, regex, replaceAll;
import std.stdio : File;
import std.string : strip, toLower;

private:

enum REQUEST_TIMEOUT = 8.seconds;
enum CONNECT_TIMEOUT = 2.seconds;
enum MAX_POLICY = 64 * 1024;
enum SECRET_FIELDS = `secret|password|token|api[_-]?key|authorization|credential|(?:session|prompt)[_-]?id`;
enum CONTENT_FIELDS = `content|text|body|data|patch|diff|source|cell|old_string|new_string`;

enum Action : string
{
    @serdeKeys("deny") Deny = "deny",
    @serdeKeys("allow") Allow = "allow",
    @serdeKeys("screen") Screen = "screen"
}

struct Rule
{
private:
    @serdeIgnore Regex!char[string] patterns;

public:
    Action action;
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
        enforce(action != Action.Screen || question.length, "A screen rule requires a question");
        foreach (field, pattern; match)
        {
            enforce(field.length && !field.canFind('\0'), "Invalid policy match field");
            patterns[field] = regex(pattern);
        }

        foreach (ref field; expose)
        {
            field = field.toLower;
            enforce(field.length && field.matchFirst(ctRegex!(SECRET_FIELDS, "i")).empty,
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

struct Document
{
public:
    Rule[] rules;
}

Rule[] load(string directory)
{
    File file = openFile(buildPath(directory, ".devin", "policy.yml"), O_RDONLY);
    scope(exit)
        file.close();

    enforce(file.size <= MAX_POLICY, "Workspace policy is too large");
    string content = cast(string)file.byChunk(4096).join;
    enforce(content.length <= MAX_POLICY, "Workspace policy is too large");
    Document document = deserializeYaml!Document(content);
    foreach (ref rule; document.rules)
        rule.compile();

    return document.rules;
}

string redact(string text)
{
    return text
        .replaceAll(ctRegex!(`(bearer\s+)[A-Za-z0-9._+/-]+`, "i"), "$1[REDACTED]")
        .replaceAll(ctRegex!(
            `((?:[A-Za-z0-9_-]*(?:api[_-]?key|token|secret|password|session[_-]?id))["']?\s*(?:[=:]|\s)\s*)`~
                `(?:"[^"]*"|'[^']*'|[^\s;&|]+)`,
            "i"
        ), "$1[REDACTED]")
        .replaceAll(ctRegex!(`\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`, "i"),
            "[REDACTED]")
        .replaceAll(ctRegex!(`\b(?:sk|pk)-[A-Za-z0-9_-]{16,}\b`), "[REDACTED]");
}

JSONValue scrub(JSONValue value, const string[] expose)
{
    if (value.type == JSONType.string)
        return JSONValue(redact(value.str));
    if (value.type != JSONType.object && value.type != JSONType.array)
        return value;

    JSONValue ret = value.type == JSONType.object ? JSONValue.emptyObject : JSONValue.emptyArray;
    if (value.type == JSONType.object)
    {
        foreach (field, item; value.object)
        {
            if (!field.matchFirst(ctRegex!(SECRET_FIELDS, "i")).empty)
                continue;
            if (!field.matchFirst(ctRegex!(CONTENT_FIELDS, "i")).empty && !expose.canFind(field.toLower))
                continue;

            ret[field] = scrub(item, expose);
        }
    }
    else
    {
        ret.array.length = value.array.length;
        foreach (i, item; value.array)
            ret.array[i] = scrub(item, expose);
    }

    return ret;
}

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
    enforce("directory" in data.object && "tool" in data.object, "Expected directory and tool");
    foreach (name, value; data.object)
        enforce(name == "input" ? value.type == JSONType.object :
            (name == "directory" || name == "tool") && value.type == JSONType.string,
            "Expected string directory and tool, and optional object input");

    if ("input" !in data.object)
        data["input"] = JSONValue.emptyObject;

    try
        respond(output, policy.check(data["directory"].str, data["tool"].str, data["input"]).toJSON());
    catch (Exception)
        respond(output, PolicyResult(true, "Policy check failed").toJSON(), 503);
}

struct PolicyResult
{
public:
    bool denied;
    string reason;

    JSONValue toJSON() const
    {
        return JSONValue([
            "denied": JSONValue(denied),
            "reason": reason.length ? JSONValue(reason) : JSONValue(null)
        ]);
    }
}

class Policy
{
private:
    IRouter router;

public:
    const string model;

    this(IRouter router, string model)
    {
        enforce(router !is null && model.length && !model.canFind('\0'), "A policy router and model are required");
        this.router = router;
        this.model = model;
        router.connectTimeout(CONNECT_TIMEOUT);
    }

    PolicyResult check(string directory, string tool, JSONValue input = JSONValue.emptyObject)
    {
        router.context.clear();
        scope(exit)
            router.context.clear();

        enforce(directory.length && isDir(directory), "An existing working directory is required");
        enforce(tool.length && !tool.canFind('\0'), "A tool name is required");
        enforce(input.type == JSONType.object, "Tool input must be an object");
        foreach (rule; load(directory))
        {
            if (!rule.matches(tool, input))
                continue;

            final switch (rule.action)
            {
                case Action.Allow:
                    return PolicyResult(false);
                case Action.Deny:
                    return PolicyResult(true, rule.reason.length ? rule.reason : "Denied by workspace policy");
                case Action.Screen:
                    MonoTime deadline = MonoTime.currTime + REQUEST_TIMEOUT;
                    router.operationTimeout(REQUEST_TIMEOUT);
                    if (router.active != model)
                        router.active(model);

                    enforce(MonoTime.currTime < deadline, "Policy request timed out");
                    router.operationTimeout(deadline - MonoTime.currTime);
                    JSONValue state = JSONValue([
                        "tool": JSONValue(tool),
                        "input": scrub(input, rule.expose)
                    ]);
                    if (rule.context.length)
                        state["context"] = JSONValue(rule.context);

                    DecisionQuestion question;
                    question.name = "harmful";
                    question.instructions = rule.question;
                    Decision decision = decisions(router, state, [question]);
                    enforce(decision.answer.type == DecisionType.Predicate, "Policy model returned no decision");
                    if (decision.answer.probability >= rule.threshold)
                        return PolicyResult(true, rule.reason.length ? rule.reason : "Denied by workspace policy");

                    return PolicyResult(false);
            }
        }

        return PolicyResult(true, "No policy rule matched");
    }
}
