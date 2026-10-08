module autonom.policy.input;

import std.algorithm.searching : canFind;
import std.json : JSONType, JSONValue;
import std.regex : ctRegex, matchFirst, replaceAll;
import std.string : toLower;

private:

enum SECRET_FIELDS = `secret|password|token|api[_-]?key|authorization|credential|(?:session|prompt)[_-]?id`;
enum CONTENT_FIELDS = `content|text|body|data|patch|diff|source|cell|old_string|new_string`;
enum KEY_VALUE = `([A-Za-z0-9_-]*(?:api[_-]?key|token|secret|password|session[_-]?id)`~
    `["']?\s*(?:[=:]|\s)\s*)(?:"[^"]*"|'[^']*'|[^\s;&|]+)`;

string redact(string text)
{
    string ret = text.replaceAll(ctRegex!(`(bearer\s+)[A-Za-z0-9._+/-]+`, "i"), "$1[REDACTED]");
    ret = ret.replaceAll(ctRegex!(KEY_VALUE, "i"), "$1[REDACTED]");
    ret = ret.replaceAll(ctRegex!(`\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`, "i"),
        "[REDACTED]");
    ret = ret.replaceAll(ctRegex!(`\b(?:sk|pk)-[A-Za-z0-9_-]{16,}\b`), "[REDACTED]");
    return ret;
}

package(autonom.policy):

bool isCredentialField(string field)
    => !field.matchFirst(ctRegex!(SECRET_FIELDS, "i")).empty;

JSONValue scrub(JSONValue value, const string[] expose)
{
    JSONValue ret;
    switch (value.type)
    {
    case JSONType.string:
        return JSONValue(redact(value.str));
    case JSONType.object:
        ret = JSONValue.emptyObject;
        foreach (field, item; value.object)
        {
            if (field.isCredentialField)
                continue;
            if (!field.matchFirst(ctRegex!(CONTENT_FIELDS, "i")).empty && !expose.canFind(field.toLower))
                continue;

            ret[field] = scrub(item, expose);
        }
        break;
    case JSONType.array:
        ret = JSONValue.emptyArray;
        ret.array.length = value.array.length;
        foreach (i, item; value.array)
            ret.array[i] = scrub(item, expose);

        break;
    default:
        return value;
    }

    return ret;
}
