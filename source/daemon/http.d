module daemon.http;

import daemon.exception;
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

bool acceptMethod(Request request, Output output, Request.Method[] methods)
{
    if (methods.canFind(request.method))
        return true;

    string[] names;
    foreach (method; methods)
        names ~= method.to!string.toUpper;

    output.addHeader("allow", names.join(", "));
    respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
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

JSONValue readLaunch(Request request)
{
    JSONValue ret = readBody(request);
    if ("prompt" !in ret.object || "directory" !in ret.object)
        throw new InvalidInputException("Expected prompt and directory");
    foreach (name, value; ret.object)
    {
        if (name == "trusted" && (value.type == JSONType.true_ || value.type == JSONType.false_))
            continue;
        if ((name != "prompt" && name != "directory" && name != "model" && name != "profile" && name != "mode") ||
            value.type != JSONType.string)
            throw new InvalidInputException("Invalid session launch field");
    }

    foreach (field; ["model", "profile", "mode"])
    {
        if (field !in ret.object)
            ret[field] = JSONValue("");
    }

    if ("trusted" !in ret.object)
        ret["trusted"] = JSONValue(false);

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
