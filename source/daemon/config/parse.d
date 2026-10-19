module daemon.config.parse;

import daemon.config.secret : resolveSecret;
import intuit.router : IRouter, OpenRouter;
import mir.algebraic_alias.yaml;
import mir.deser.yaml;

import core.time : Duration, seconds;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.ascii : isDigit;
import std.conv : to;
import std.path : absolutePath, buildNormalizedPath, expandTilde;
import std.string : strip;

string resolvePath(string path, string base)
    => buildNormalizedPath(absolutePath(expandTilde(path), base));

Duration parseDuration(string text, string name)
{
    if (!text.length)
        throw new Exception(name~" must be a duration such as 30m or 1h");

    long scale = 1;
    string digits = text;
    char unit = text[$-1];
    if (!isDigit(unit))
    {
        switch (unit)
        {
        case 's':
            break;

        case 'm':
            scale = 60;
            break;

        case 'h':
            scale = 3600;
            break;

        case 'd':
            scale = 86400;
            break;

        default:
            throw new Exception(name~" must be a duration such as 30m or 1h");
        }

        digits = text[0..$-1];
    }

    long value;
    try
        value = digits.to!long;
    catch (Exception)
        throw new Exception(name~" must be a duration such as 30m or 1h");

    if (value < 1)
        throw new Exception(name~" must be a positive duration");

    return (value * scale).seconds;
}

Duration readDuration(YamlAlgebraic value, string name)
{
    if (value.kind == YamlAlgebraic.Kind.integer)
    {
        long seconds = value.get!long;
        if (seconds < 1)
            throw new Exception(name~" must be a positive duration");

        return seconds.seconds;
    }

    if (value.kind != YamlAlgebraic.Kind.string)
        throw new Exception(name~" must be a duration such as 30m or 1h");

    return parseDuration(value.get!string, name);
}

size_t readPositiveInteger(YamlAlgebraic value, string name)
{
    long integer;
    if (value.kind == YamlAlgebraic.Kind.integer)
        integer = value.get!long;
    else if (value.kind == YamlAlgebraic.Kind.string)
    {
        try
            integer = value.get!string.strip.to!long;
        catch (Exception)
            throw new Exception(name~" must be a positive integer");
    }
    else
        throw new Exception(name~" must be a positive integer");

    if (integer < 1)
        throw new Exception(name~" must be a positive integer");

    return cast(size_t)integer;
}

size_t readByteSize(YamlAlgebraic value, string name)
{
    if (value.kind == YamlAlgebraic.Kind.integer)
    {
        long bytes = value.get!long;
        if (bytes < 1)
            throw new Exception(name~" must be a positive byte size");

        return cast(size_t)bytes;
    }
    if (value.kind != YamlAlgebraic.Kind.string)
        throw new Exception(name~" must be a byte size such as 4MB or 16MiB");

    string text = value.get!string.strip;
    if (!text.length)
        throw new Exception(name~" must not be empty");

    size_t scale = 1;
    string digits = text;
    if (text.endsWith("GiB") || text.endsWith("gib"))
    {
        scale = 1024 * 1024 * 1024;
        digits = text[0..$-3].strip;
    }
    else if (text.endsWith("GB") || text.endsWith("gb"))
    {
        scale = 1000 * 1000 * 1000;
        digits = text[0..$-2].strip;
    }
    else if (text.endsWith("MiB") || text.endsWith("mib"))
    {
        scale = 1024 * 1024;
        digits = text[0..$-3].strip;
    }
    else if (text.endsWith("MB") || text.endsWith("mb"))
    {
        scale = 1000 * 1000;
        digits = text[0..$-2].strip;
    }
    else if (text.endsWith("KiB") || text.endsWith("kib"))
    {
        scale = 1024;
        digits = text[0..$-3].strip;
    }
    else if (text.endsWith("KB") || text.endsWith("kb"))
    {
        scale = 1000;
        digits = text[0..$-2].strip;
    }
    else if (text.endsWith("B") || text.endsWith("b"))
    {
        scale = 1;
        digits = text[0..$-1].strip;
    }

    long val;
    try
        val = digits.to!long;
    catch (Exception)
        throw new Exception(name~" must be a byte size such as 4MiB or 16MB");

    if (val < 1)
        throw new Exception(name~" must be a positive byte size");

    return cast(size_t)(val * scale);
}

IRouter createRouter(YamlAlgebraic settings, string directory)
{
    if (settings.kind != YamlAlgebraic.Kind.object)
        throw new Exception("Router configuration must be a mapping");

    string[string] values;
    foreach (pair; settings.object.pairs)
    {
        if (pair.key.kind != YamlAlgebraic.Kind.string)
            throw new Exception("Router setting names must be strings");

        string field = pair.key.get!string.idup;
        if (field in values)
            throw new Exception("Duplicate router setting: "~field);
        if (pair.value.kind != YamlAlgebraic.Kind.string)
            throw new Exception("Router settings must be strings");

        string value = pair.value.get!string.idup;
        if (value.canFind('\0'))
            throw new Exception("Invalid router setting");

        switch (field)
        {
        case "type", "key", "url", "name", "referer", "title":
            values[field] = value;
            break;

        default:
            throw new Exception("Unknown router setting: "~field);
        }
    }

    foreach (field; ["type", "key", "url", "name"])
    {
        if (field !in values || !values[field].length)
            throw new Exception("Router requires "~field);
    }

    string url = values["url"];
    if (!((url.startsWith("https://") && url.length > 8) ||
        (url.startsWith("http://") && url.length > 7)))
        throw new Exception("Router URL must use HTTP or HTTPS");

    if (values["type"] != "openrouter")
        throw new Exception("Unsupported router type");

    OpenRouter ret = new OpenRouter(resolveSecret(values["key"], directory), url, values["name"]);
    ret.referer = values.get("referer", null);
    ret.title = values.get("title", null);
    return ret;
}
