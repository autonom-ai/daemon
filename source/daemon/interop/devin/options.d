module daemon.interop.devin.options;

import daemon.exception;
import daemon.interop.acp;

import core.time : seconds;
import std.json : JSONType, JSONValue;

JSONValue sessionParams(string directory, string sessionId = null)
{
    JSONValue ret = JSONValue([
        "cwd": JSONValue(directory),
        "mcpServers": JSONValue.emptyArray,
        "_meta": JSONValue(["autonom/connector": JSONValue("autonom")])
    ]);
    if (sessionId.length)
        ret["sessionId"] = JSONValue(sessionId);

    return ret;
}

JSONValue promptParams(string sessionId, string prompt)
{
    return JSONValue([
        "sessionId": JSONValue(sessionId),
        "prompt": JSONValue([JSONValue(["type": JSONValue("text"),
        "text": JSONValue(prompt)])])
    ]);
}

JSONValue optionParams(string sessionId, string configId, string value)
{
    return JSONValue([
        "sessionId": JSONValue(sessionId),
        "configId": JSONValue(configId),
        "value": JSONValue(value)
    ]);
}

string normalizeMode(string mode)
{
    switch (mode)
    {
    case "":
        return null;
    case "dangerous":
    case "autonomous":
        return "bypass";
    case "auto":
    case "normal":
        return "ask";
    case "code":
        return "accept-edits";
    case "accept-edits":
    case "smart":
    case "ask":
    case "plan":
    case "bypass":
        return mode;
    default:
        throw new InvalidInputException("Invalid permission mode");
    }
}

void applyOptions(AcpClient agent, JSONValue created, string sessionId, string model, string mode)
{
    string requestedMode = normalizeMode(mode);
    if (requestedMode.length)
    {
        validateOption(created, "mode", requestedMode);
        agent.request("session/set_config_option",
            optionParams(sessionId, "mode", requestedMode), 15.seconds);
    }
    if (model.length)
    {
        validateOption(created, "model", model);
        agent.request("session/set_config_option",
            optionParams(sessionId, "model", model), 15.seconds);
    }
}

void validateOption(JSONValue created, string configId, string value)
{
    if ("configOptions" !in created.object || created["configOptions"].type != JSONType.array)
        return;

    foreach (option; created["configOptions"].array)
    {
        if (option.type != JSONType.object || "id" !in option.object || option["id"].str != configId ||
            "options" !in option.object || option["options"].type != JSONType.array)
            continue;

        bool allowed;
        foreach (entry; option["options"].array)
        {
            if (entry.type == JSONType.object && "value" in entry.object && entry["value"].str == value)
                allowed = true;
        }

        if (!allowed)
            throw new InvalidInputException("Unsupported "~configId~" value");
    }
}
