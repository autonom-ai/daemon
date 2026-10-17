module daemon.interop.metadata;

import std.json : JSONValue;

struct SessionMetadata
{
    string id;
    string model;
    string directory;
    string title;
    string mode;
    string backend;
    string acp;
    long createdAt;
    long lastActivityAt;
    bool hidden;
    JSONValue workspaces = JSONValue.emptyArray;

    JSONValue toJSON()
    {
        return JSONValue([
            "id": JSONValue(id),
            "model": JSONValue(model),
            "directory": JSONValue(directory),
            "title": JSONValue(title),
            "mode": JSONValue(mode),
            "backend": JSONValue(backend),
            "acp": acp.length ? JSONValue(acp) : JSONValue(null),
            "createdAt": JSONValue(createdAt),
            "lastActivityAt": JSONValue(lastActivityAt),
            "hidden": JSONValue(hidden),
            "workspaces": workspaces
        ]);
    }
}
