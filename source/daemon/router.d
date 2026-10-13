module daemon.router;

import intuit.router : IRouter, OpenRouter;
import mir.algebraic_alias.yaml;

import std.algorithm.searching : canFind, startsWith;

package(daemon):

IRouter createRouter(YamlAlgebraic settings)
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

    foreach (field; [
        "type",
        "key",
        "url",
        "name"
    ])
    {
        if (field !in values || !values[field].length)
            throw new Exception("Router requires "~field);
    }

    string url = values["url"];
    if (!((url.startsWith("https://") && url.length > 8) ||
        (url.startsWith("http://") && url.length > 7)))
        throw new Exception("Router URL must use HTTP or HTTPS");
    switch (values["type"])
    {
    case "openrouter":
        OpenRouter ret = new OpenRouter(values["key"], url, values["name"]);
        ret.referer = values.get("referer", null);
        ret.title = values.get("title", null);
        return ret;

    default:
        throw new Exception("Unsupported router type");
    }
}
