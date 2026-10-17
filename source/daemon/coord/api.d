module daemon.coord.api;

import daemon.agent;
import daemon.api;
import daemon.coord;
import daemon.exception;
import daemon.http;

import serverino;

import std.conv : to;
import std.json : JSONType, JSONValue;
import std.string : strip;

private enum defaultLimit = 50;
private enum maxLimit = 500;
private enum maxText = 4000;

package(daemon.coord):
size_t readLimit(Request request)
{
    string value = request.get.read("limit");
    if (!value.length)
        return defaultLimit;

    size_t ret;
    try
        ret = value.to!size_t;
    catch (Exception)
        throw new InvalidInputException("Invalid limit");

    if (ret < 1)
        return 1;

    return ret > maxLimit ? maxLimit : ret;
}

string[] names(JSONValue value, string message)
{
    if (value.type != JSONType.array)
        throw new InvalidInputException(message);

    string[] ret = new string[0];
    foreach (entry; value.array)
    {
        if (entry.type != JSONType.string)
            throw new InvalidInputException(message);

        ret ~= entry.str;
    }

    return ret;
}

string messageText(JSONValue data)
{
    if ("text" !in data.object || data["text"].type != JSONType.string)
        throw new InvalidInputException("A message needs text");

    string ret = data["text"].str;
    if (!ret.strip.length)
        throw new InvalidInputException("A message needs text");
    if (ret.length > maxText)
        throw new InvalidInputException("Message text is too long");

    return ret;
}

string[] pingNames(JSONValue data)
{
    if ("ping" !in data.object || data["ping"].isNull)
        return null;

    return names(data["ping"], "Ping must be a list of profile names");
}

JSONValue entryArray(Entry[] entries)
{
    JSONValue ret = JSONValue.emptyArray;
    foreach (entry; entries)
        ret.array ~= entry.toJSON();

    return ret;
}

JSONValue messageResult(Entry entry, Profile[] targets)
{
    JSONValue ret = entry.toJSON();
    ret["pinged"] = JSONValue.emptyArray;
    foreach (target; targets)
        ret["pinged"].array ~= JSONValue(target.name);

    return ret;
}

Profile profileByName(string name, Output output)
{
    Profile ret = profileStore.get(name);
    if (ret is null)
        respondError(output, 404, "Profile not found");

    return ret;
}

bool profileList(string[] profileNames, Output output, out Profile[] targets)
{
    targets = new Profile[0];
    foreach (name; profileNames)
    {
        Profile found = profileByName(name, output);
        if (found is null)
            return false;

        targets ~= found;
    }

    return true;
}

Room lookup(string name, Profile profile, Output output, bool delegate(Room room) access) {
    Room ret = bus.getRoom(name);
    if (ret is null || !access(ret))
    {
        respondError(output, 404, "Unknown room");
        return null;
    }

    return ret;
}
