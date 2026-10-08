module autonom.profile;

import autonom.session.session : Session;

import std.json : JSONValue;

class Profile
{
public:
    const string name;
    Session session;

    this(string name, Session session = null)
    {
        this.name = name;
        this.session = session;
    }

    JSONValue toJSON()
    {
        return JSONValue([
            "name": JSONValue(name),
            "session": session is null ? JSONValue(null) : session.toJSON()
        ]);
    }
}
