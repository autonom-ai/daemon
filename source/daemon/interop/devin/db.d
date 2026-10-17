module daemon.interop.devin.db;

import daemon.interop.metadata : SessionMetadata;
import arsd.sqlite;

import std.conv : to;
import std.file : exists, isFile, isSymlink;
import std.json : JSONType, JSONValue, parseJSON;

public:

SessionMetadata readSessionMetadata(string database, string id)
{
    SessionMetadata ret;
    if (!available(database))
        return ret;

    Sqlite connection = openDatabase(database);
    scope(exit)
        destroy(connection);

    ResultSet result = connection.query(
        "select id, model, working_directory, coalesce(title, '') as title, agent_mode, backend_type, "~
        "created_at, last_activity_at, hidden, coalesce(workspace_dirs, '[]') as workspace_dirs, metadata "~
        "from sessions where id = ?",
        id
    );
    scope(exit)
        destroy(result);
    if (result.empty)
        return ret;

    return metadata(result.front);
}

SessionMetadata[] readSessionCatalog(string database)
{
    SessionMetadata[] ret;
    if (!available(database))
        return ret;

    Sqlite connection = openDatabase(database);
    scope(exit)
        destroy(connection);

    ResultSet result = connection.query(
        "select id, model, working_directory, coalesce(title, '') as title, agent_mode, backend_type, "~
        "created_at, last_activity_at, hidden, coalesce(workspace_dirs, '[]') as workspace_dirs, metadata "~
        "from sessions order by created_at, id"
    );
    scope(exit)
        destroy(result);

    foreach (Row row; result)
        ret ~= metadata(row);

    return ret;
}

private Sqlite openDatabase(string database)
{
    Sqlite ret = new Sqlite(database, SQLITE_OPEN_READONLY);
    scope(failure)
        destroy(ret);

    ret.query("pragma busy_timeout = 250");
    return ret;
}

private SessionMetadata metadata(Row row)
{
    SessionMetadata ret;
    ret.id = row["id"].toString();
    ret.model = row["model"].toString();
    ret.directory = row["working_directory"].toString();
    ret.title = row["title"].toString();
    ret.mode = row["agent_mode"].toString();
    ret.backend = row["backend_type"].toString();
    string stored = row["metadata"].toString();
    if (stored.length)
    {
        JSONValue data = parseJSON(stored);
        if (data.type == JSONType.object && "client_meta" in data.object &&
            data["client_meta"].type == JSONType.object)
        {
            JSONValue* connector = "autonom/connector" in data["client_meta"].object;
            if (connector !is null && connector.type == JSONType.string)
                ret.acp = connector.str;
        }
    }
    ret.createdAt = row["created_at"].toString().to!long;
    ret.lastActivityAt = row["last_activity_at"].toString().to!long;
    ret.hidden = row["hidden"].toString() != "0";
    ret.workspaces = parseJSON(row["workspace_dirs"].toString());
    if (ret.workspaces.type != JSONType.array)
        ret.workspaces = JSONValue.emptyArray;

    return ret;
}

JSONValue readSessionMessages(string database, string id, size_t limit = 300)
{
    JSONValue ret = JSONValue.emptyArray;
    if (!available(database))
        return ret;

    Sqlite connection = openDatabase(database);
    scope(exit)
        destroy(connection);

    ResultSet result = connection.query(
        "with recursive chain(node_id, parent_node_id, chat_message, created_at, depth) as ("~
        "select node_id, parent_node_id, chat_message, created_at, 0 from message_nodes "~
        "where session_id = ? and node_id = (select main_chain_id from sessions where id = ?) "~
        "union all select nodes.node_id, nodes.parent_node_id, nodes.chat_message, nodes.created_at, chain.depth + 1 "~
        "from message_nodes nodes join chain on nodes.node_id = chain.parent_node_id "~
        "where nodes.session_id = ? and chain.depth < ?) "~
        "select node_id, substr(chat_message, 1, 262144) as chat_message, created_at "~
        "from chain where length(chat_message) <= 262144 order by depth desc",
        id,
        id,
        id,
        limit > 500 ? 500 : limit
    );
    scope(exit)
        destroy(result);

    size_t bytes;
    foreach (Row row; result)
    {
        string text = row["chat_message"].toString();
        if (bytes + text.length > 4 * 1024 * 1024)
            break;

        JSONValue message = parseJSON(text);
        if (message.type != JSONType.object || "role" !in message.object ||
            message["role"].type != JSONType.string || message["role"].str == "system")
            continue;

        bytes += text.length;
        message["nodeId"] = JSONValue(row["node_id"].toString().to!long);
        message["timestamp"] = JSONValue(row["created_at"].toString().to!long);
        ret.array ~= message;
    }

    return ret;
}

private:

bool available(string database)
{
    if (!database.length || !exists(database))
        return false;
    if (!isFile(database) || isSymlink(database))
        throw new Exception("Session database must be a regular file");

    return true;
}
