module tests.interop.devin.common;

import tests.common : Fixture;

import arsd.sqlite;

Sqlite database(Fixture fixture)
{
    Sqlite ret = new Sqlite(fixture.config.sessionDatabase);
    ret.query("create table sessions (id text primary key, model text, working_directory text, title text, "~
        "agent_mode text, backend_type text, created_at integer, last_activity_at integer, hidden integer, "~
        "workspace_dirs text, main_chain_id integer, metadata text)");
    ret.query("create table message_nodes (session_id text, node_id integer, parent_node_id integer, "~
        "chat_message text, created_at integer)");
    ret.query("insert into sessions values ('session-one', 'swe-2-medium', ?, 'First title', 'bypass', 'cli', "~
        "100, 200, 0, '[]', 3, null)", fixture.root);
    return ret;
}

