/// SQL representation of profiles, current bindings, and retained backend associations.
module daemon.db.profiles;

import daemon.db : Connection;
import daemon.exception : ConflictException;
import daemon.interop.session : SessionKey;

import arsd.sqlite : ResultSet, Row;

import std.typecons : Nullable;

/// An owned snapshot. Liveness and bearer capabilities are deliberately absent.
struct StoredProfile
{
    string name;
    Nullable!SessionKey current;
}

/// Profile persistence borrowed from a worker-owned connection, not an admission authority.
class Profiles
{
private:
    Connection connection;

public:
    this(Connection connection)
    {
        this.connection = connection;
    }

    /// Create an unbound canonical profile; the virtual human identity remains reserved.
    void create(string name)
    {
        connection.transaction({
            connection.query("insert into profiles(name) values (?)", name);
            connection.query("insert into profile_bindings(profile_name) values (?)", name);
        });
    }

    /// List independent snapshots in canonical name order.
    StoredProfile[] list()
    {
        ResultSet rows = connection.query(
            "select p.name, coalesce(b.provider, '') as provider, coalesce(b.session_id, '') as session_id "~
            "from profiles p left join profile_bindings b on b.profile_name = p.name order by p.name"
        );
        scope(exit)
            destroy(rows);

        StoredProfile[] ret;
        foreach (Row row; rows)
            ret ~= readProfile(row);
        return ret;
    }

    /// Find one profile without acquiring a backend or restoring live process state.
    Nullable!StoredProfile get(string name)
    {
        ResultSet rows = connection.query(
            "select p.name, coalesce(b.provider, '') as provider, coalesce(b.session_id, '') as session_id "~
            "from profiles p left join profile_bindings b on b.profile_name = p.name where p.name = ?", name
        );
        scope(exit)
            destroy(rows);

        return rows.empty ? Nullable!StoredProfile.init : Nullable!StoredProfile(readProfile(rows.front));
    }

    /// Persist an admitted binding atomically, retaining earlier associations.
    /// The domain caller must check active replacement and caller authority before entering.
    void bind(string profile, SessionKey key)
    {
        key.validate();
        connection.transaction({
            retainEntry(profile, key);
            connection.query(
                "insert into profile_bindings(profile_name, provider, session_id) values (?, ?, ?) "~
                "on conflict(profile_name) do update set provider = excluded.provider, session_id = excluded.session_id",
                profile, key.provider, key.id
            );
        });
    }

    /// Clear the current binding without erasing historical attribution.
    void unbind(string profile)
    {
        connection.transaction({
            connection.query(
                "insert into profile_bindings(profile_name) values (?) "~
                "on conflict(profile_name) do update set provider = null, session_id = null", profile
            );
        });
    }

    /// Retain a historical association without making it current.
    void retain(string profile, SessionKey key)
    {
        key.validate();
        connection.transaction({
            retainEntry(profile, key);
        });
    }

    /// Return attribution in stable key order, not a claim about transcript chronology.
    SessionKey[] history(string profile)
    {
        ResultSet rows = connection.query(
            "select provider, session_id from session_associations where profile_name = ? "~
            "order by provider, session_id", profile
        );
        scope(exit)
            destroy(rows);

        SessionKey[] ret;
        foreach (Row row; rows)
            ret ~= SessionKey(row["provider"], row["session_id"]);
        return ret;
    }

package(daemon.db):
    void retainEntry(string profile, SessionKey key)
    {
        connection.query(
            "insert or ignore into session_associations(provider, session_id, profile_name) values (?, ?, ?)",
            key.provider, key.id, profile
        );
        ResultSet rows = connection.query(
            "select profile_name from session_associations where provider = ? and session_id = ?",
            key.provider, key.id
        );
        scope(exit)
            destroy(rows);
        if (rows.empty || rows.front["profile_name"] != profile)
            throw new ConflictException("Session is already assigned to another profile");
    }

private:
    static StoredProfile readProfile(Row row)
    {
        StoredProfile ret;
        ret.name = row["name"].toString.idup;
        string provider = row["provider"];
        if (provider.length)
            ret.current = SessionKey(provider, row["session_id"]);
        return ret;
    }
}
