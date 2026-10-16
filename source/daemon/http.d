module daemon.http;

import daemon.agent;
import daemon.exception;
import daemon.runtime;
import serverino;

import std.algorithm : canFind, endsWith, startsWith;
import std.array : join;
import std.conv : to;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : indexOf, toUpper;

package(daemon):

void respond(Output output, JSONValue body, ushort status = 200)
{
    output.status = status;
    output.addHeader("content-type", "application/json");
    output.addHeader("cache-control", "no-store");
    output ~= body.toString();
}

void respondError(Output output, ushort status, string message)
{
    respond(output, JSONValue(["error": JSONValue(message)]), status);
}

bool acceptMethod(Request request, Output output, Request.Method[] methods)
{
    if (methods.canFind(request.method))
        return true;

    string[] names;
    foreach (method; methods)
        names ~= method.to!string.toUpper;

    output.addHeader("allow", names.join(", "));
    respondError(output, 405, "Method not allowed");
    return false;
}

string routeParameter(string PATTERN)(const Request request)
{
    enum START = PATTERN.indexOf('<');
    enum END = PATTERN.indexOf('>');
    static assert(START >= 0 && END > START && PATTERN[END + 1..$].indexOf('<') < 0);
    enum PREFIX = PATTERN[0..START];
    enum SUFFIX = PATTERN[END + 1..$];
    if (!request.path.startsWith(PREFIX) || !request.path.endsWith(SUFFIX) ||
        request.path.length <= PREFIX.length + SUFFIX.length)
        return null;

    string ret = request.path[PREFIX.length..$-SUFFIX.length];
    return ret.canFind('/') ? null : ret;
}

bool matchesPath(string PATTERN)(const Request request)
    => routeParameter!PATTERN(request).length != 0;

JSONValue readBody(Request request, size_t limit = 64 * 1024)
{
    enum MIME = "application/json";
    if (request.body.contentType != MIME && !request.body.contentType.startsWith(MIME~";"))
        throw new InvalidInputException("Expected application/json");
    if (request.body.data.length > limit)
        throw new InvalidInputException("Request body is too large");

    JSONValue ret;
    try
        ret = parseJSON(request.body.data);
    catch (Exception)
        throw new InvalidInputException("Invalid JSON body");

    if (ret.type != JSONType.object)
        throw new InvalidInputException("Expected a JSON object");

    return ret;
}

struct Launch
{
    string prompt;
    string directory;
    string model;
    string profile;
    string mode;
    bool trusted;
}

Launch readLaunch(Request request)
{
    JSONValue data = readBody(request);
    if ("prompt" !in data.object || "directory" !in data.object)
        throw new InvalidInputException("Expected prompt and directory");
    onlyFields(data, ["prompt", "directory", "model", "profile", "mode", "trusted"]);

    Launch ret;
    foreach (name, value; data.object)
    {
        if (name == "trusted")
        {
            if (value.type != JSONType.true_ && value.type != JSONType.false_)
                throw new InvalidInputException("Invalid session launch field");
            ret.trusted = value.boolean;
            continue;
        }
        if (value.type != JSONType.string)
            throw new InvalidInputException("Invalid session launch field");
        switch (name)
        {
        case "prompt":
            ret.prompt = value.str;
            break;
        case "directory":
            ret.directory = value.str;
            break;
        case "model":
            ret.model = value.str;
            break;
        case "profile":
            ret.profile = value.str;
            break;
        default:
            ret.mode = value.str;
        }
    }

    return ret;
}

string readField(string FIELD)(Request request)
{
    JSONValue data = readBody(request);
    if (data.object.length != 1 || FIELD !in data.object)
        throw new InvalidInputException("Expected only the "~FIELD~" field");
    if (data[FIELD].type != JSONType.string)
        throw new InvalidInputException(FIELD~" must be a string");

    return data[FIELD].str;
}

void onlyFields(JSONValue data, string[] fields)
{
    foreach (name; data.object.keys)
    {
        if (!fields.canFind(name))
            throw new InvalidInputException("Unexpected "~name~" field");
    }
}

Profile caller(Request request)
{
    string session = request.get.read("session");
    bool human = bridge.access.client(request.header.read("x-autonom-client"));
    if (human && request.get.has("profile") &&
        (request.path == "/api/events" || request.path == "/api/schedules" ||
        request.path.startsWith("/api/schedules/")))
    {
        Profile ret = profileStore.get(request.get.read("profile"));
        if (ret is null)
            throw new InvalidInputException("Unknown profile");

        return ret;
    }

    string bound = bridge.access.mcpSession(request.header.read("x-autonom-mcp"));
    if (bound.length)
        session = bound;

    if (!session.length)
    {
        if (human)
            return profileStore.get(HUMAN_NAME);

        throw new InvalidInputException("A session is required");
    }
    if (!human && !bound.length &&
        bridge.authenticate(request.header.read("x-autonom-run"), session) is null)
        throw new InvalidInputException("Invalid managed session capability");

    Profile ret = profileStore.profileFor(session);
    if (ret is null)
        throw new ConflictException("No profile is registered for this session");

    return ret;
}
