module autonom.router;

import intuit.router : IRouter, OpenRouter;
import mir.algebraic_alias.yaml;

import std.algorithm.searching : canFind, startsWith;
import std.exception : enforce;

package(autonom):

IRouter createRouter(YamlAlgebraic settings)
{
    enforce(settings.kind == YamlAlgebraic.Kind.object, "Router configuration must be a mapping");
    string[string] values;
    foreach (pair; settings.object.pairs)
    {
        enforce(pair.key.kind == YamlAlgebraic.Kind.string, "Router setting names must be strings");
        string field = pair.key.get!string.idup;
        enforce(field !in values, "Duplicate router setting: "~field);
        enforce(pair.value.kind == YamlAlgebraic.Kind.string, "Router settings must be strings");
        string value = pair.value.get!string.idup;
        enforce(!value.canFind('\0'), "Invalid router setting");
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
        enforce(field in values && values[field].length, "Router requires "~field);

    string url = values["url"];
    enforce((url.startsWith("https://") && url.length > 8) || (url.startsWith("http://") && url.length > 7),
        "Router URL must use HTTP or HTTPS");
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
