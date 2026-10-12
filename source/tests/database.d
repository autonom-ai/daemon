module tests.database;

import autonom.interop.devin.db;
import tests.common;
import arsd.sqlite;
import unit_threaded : Name, should;

import std.file : symlink;
import std.json : JSONValue;
import std.path : buildPath;

private:

Sqlite database(Fixture fixture)
{
    Sqlite ret = new Sqlite(fixture.config.sessionDatabase);
    ret.query("create table sessions (id text primary key, model text, working_directory text, title text, "~
        "agent_mode text, backend_type text, created_at integer, last_activity_at integer, hidden integer, "~
        "workspace_dirs text, main_chain_id integer)");
    ret.query("create table message_nodes (session_id text, node_id integer, parent_node_id integer, "~
        "chat_message text, created_at integer)");
    ret.query("insert into sessions values ('session-one', 'swe-2-medium', ?, 'First title', 'bypass', 'cli', "~
        "100, 200, 0, '[]', 3)", fixture.root);
    return ret;
}

public:

@Name("Session metadata reads current title, model, mode, workspace, and timestamps from SQLite")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Sqlite connection = database(fixture);
    scope(exit)
        destroy(connection);

    SessionMetadata metadata = readSessionMetadata(fixture.config.sessionDatabase, "session-one");
    metadata.title.should == "First title";
    metadata.model.should == "swe-2-medium";
    metadata.mode.should == "bypass";
    metadata.directory.should == fixture.root;
    metadata.createdAt.should == 100;
    metadata.lastActivityAt.should == 200;
    connection.query("update sessions set model = 'swe-2-high', title = 'Changed title', agent_mode = 'auto' "~
        "where id = 'session-one'");
    metadata = readSessionMetadata(fixture.config.sessionDatabase, "session-one");
    metadata.title.should == "Changed title";
    metadata.model.should == "swe-2-high";
    metadata.mode.should == "auto";
    readSessionMetadata(fixture.config.sessionDatabase, "missing").id.length.should == 0;
}

@Name("Conversation history follows the main chain and excludes system prompts and abandoned branches")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Sqlite connection = database(fixture);
    scope(exit)
        destroy(connection);

    connection.query("insert into message_nodes values ('session-one', 0, null, ?, 100)",
        JSONValue(["role": JSONValue("system"), "content": JSONValue("private system prompt")]).toString());
    connection.query("insert into message_nodes values ('session-one', 1, 0, ?, 101)",
        JSONValue(["role": JSONValue("user"), "content": JSONValue("hello")]).toString());
    connection.query("insert into message_nodes values ('session-one', 2, 1, ?, 102)",
        JSONValue(["role": JSONValue("assistant"), "content": JSONValue("abandoned")]).toString());
    connection.query("insert into message_nodes values ('session-one', 3, 1, ?, 103)",
        JSONValue(["role": JSONValue("assistant"), "content": JSONValue("selected answer")]).toString());
    JSONValue messages = readSessionMessages(fixture.config.sessionDatabase, "session-one");
    messages.array.length.should == 2;
    messages[0]["content"].str.should == "hello";
    messages[1]["content"].str.should == "selected answer";
    messages[1]["nodeId"].integer.should == 3;
}

@Name("Database access rejects a symlink instead of reading another file")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    Sqlite connection = database(fixture);
    destroy(connection);
    string aliasPath = buildPath(fixture.root, "alias.db");
    symlink(fixture.config.sessionDatabase, aliasPath);
    bool rejected;
    try
        readSessionMetadata(aliasPath, "session-one");
    catch (Exception)
        rejected = true;

    rejected.should == true;
}
