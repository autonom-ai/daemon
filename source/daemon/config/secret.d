module daemon.config.secret;

import daemon.storage : readText;

import std.algorithm.searching : startsWith;
import std.ascii : isDigit, isUpper;
import std.file : exists;
import std.path : buildPath;
import std.string : indexOf, splitLines, strip;

enum dotEnvLimit = 64 * 1024;

// An uppercase identifier is a reference, never a literal. Credentials carry
// characters this rejects, so a bare name cannot be confused with a key.
private bool isSecretName(string name)
{
    if (!name.length || !isUpper(name[0]))
        return false;

    foreach (i, character; name)
    {
        if (i == 0)
            continue;
        if (character != '_' && !isUpper(character) && !isDigit(character))
            return false;
    }

    return true;
}

private string stripExport(string entry)
{
    if (!entry.startsWith("export "))
        return entry;

    return entry[7..entry.length].strip;
}

private string stripQuotes(string value)
{
    if (value.length < 2 || (value[0] != '"' && value[0] != '\'') || value[$-1] != value[0])
        return value;

    return value[1..value.length - 1];
}

// readText carries the storage guards, so a symlinked or oversized .env is
// refused the same way the configuration file itself is.
private string[string] readDotEnv(string path)
{
    string[string] ret;
    foreach (line; readText(path, dotEnvLimit).splitLines())
    {
        string entry = stripExport(line.strip);
        if (!entry.length || entry[0] == '#')
            continue;

        // Everything after the first '=' is the value, so it may contain '='.
        // A trailing '=' holds nothing, and an empty value is no credential.
        auto separator = entry.indexOf('=');
        if (separator <= 0 || separator == entry.length - 1)
            continue;

        // separator is the index of '=', so the name is the text before it.
        string name = entry[0..separator].strip;
        if (!isSecretName(name))
            continue;

        ret[name] = stripQuotes(entry[separator + 1..entry.length].strip).idup;
    }

    return ret;
}

/// Resolves a credential named by an uppercase identifier against `.env` beside
/// the configuration file. Anything else is returned unchanged, so an existing
/// configuration keeps working. An unresolvable reference throws; the message
/// names the variable and the file, never the credential.
string resolveSecret(string value, string directory)
{
    if (!isSecretName(value))
        return value;

    string path = buildPath(directory, ".env");
    if (!exists(path))
        throw new Exception("Credential "~value~" is not defined in "~path);

    string resolved;
    try
        resolved = readDotEnv(path).get(value, "");
    catch (Exception error)
        throw new Exception("Credential "~value~" could not be read from "~path~": "~error.msg);

    if (!resolved.length)
        throw new Exception("Credential "~value~" is not defined in "~path);

    return resolved;
}