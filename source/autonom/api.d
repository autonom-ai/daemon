module autonom.api;

import autonom.config : Config;
import autonom.profilestore : ProfileStore, ProfileConflict;
import autonom.profile : Profile;
import serverino : Output, Request;

import std.algorithm : startsWith, endsWith;
import std.exception : ErrnoException, enforce;
import std.file : FileException;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : split;

class Api
{
private:
    Config configuration;
    ProfileStore profiles;
    string prefix;

    static void respond(Output output, JSONValue body, ushort status = 200)
    {
        output.status = status;
        output.addHeader("content-type", "application/json");
        output ~= body.toString();
    }

    static string readField(string FIELD)(Request request)
    {
        enum MIME = "application/json";
        enum MAX_BODY = 64 * 1024;
        enforce(request.body.contentType == MIME || request.body.contentType.startsWith(MIME~";"),
            "Expected application/json");
        enforce(request.body.data.length <= MAX_BODY, "Request body is too large");
        JSONValue data = parseJSON(request.body.data);
        enforce(data.type == JSONType.object && data.object.length == 1 && FIELD in data.object,
            "Expected only the "~FIELD~" field");
        enforce(data[FIELD].type == JSONType.string, FIELD~" must be a string");
        return data[FIELD].str;
    }

public:
    this(Config configuration, ProfileStore profiles, string prefix = "")
    {
        enforce(prefix.length == 0 || (prefix.startsWith('/') && !prefix.endsWith('/')), "Invalid API prefix");
        this.configuration = configuration;
        this.profiles = profiles;
        this.prefix = prefix;
    }

    void route(Request request, Output output)
    {
        string path = request.path;
        if (path == prefix~"/config")
        {
            if (request.method == Request.Method.Get)
                respond(output, configuration.toJSON());
            else
                respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);

            return;
        }

        if (path != prefix~"/profiles" && !path.startsWith(prefix~"/profiles/"))
            return;

        try
        {
            if (path == prefix~"/profiles")
            {
                if (request.method == Request.Method.Get)
                {
                    JSONValue[] ret;
                    foreach (profile; profiles.list())
                        ret ~= profile.toJSON();

                    respond(output, JSONValue(ret));
                }
                else if (request.method == Request.Method.Post)
                    respond(output, profiles.create(readField!"name"(request)).toJSON(), 201);
                else
                    respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);

                return;
            }

            string[] segments = path[(prefix~"/profiles/").length..$].split('/');
            if (segments.length != 1 && (segments.length != 2 || segments[1] != "session"))
            {
                respond(output, JSONValue(["error": JSONValue("Not found")]), 404);
                return;
            }

            Profile profile = profiles.get(segments[0]);
            if (profile is null)
            {
                respond(output, JSONValue(["error": JSONValue("Profile not found")]), 404);
                return;
            }

            if (segments.length == 2 && request.method == Request.Method.Post)
                respond(output, profiles.register(profile.name, readField!"id"(request)).toJSON());
            else if (request.method != Request.Method.Get)
                respond(output, JSONValue(["error": JSONValue("Method not allowed")]), 405);
            else if (segments.length == 1)
                respond(output, profile.toJSON());
            else if (profile.session !is null)
                respond(output, profile.session.toJSON());
            else
                respond(output, JSONValue(["error": JSONValue("Profile has no session")]), 404);
        }
        catch (Exception error)
        {
            ushort status = cast(ErrnoException)error || cast(FileException)error ? 500 :
                cast(ProfileConflict)error ? 409 : 400;
            respond(output, JSONValue([
                "error": JSONValue(status == 500 ? "Could not access storage" : error.msg)
            ]), status);
        }
    }
}
