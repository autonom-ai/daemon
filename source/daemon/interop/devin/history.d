module daemon.interop.devin.history;

import daemon.interop.call : Call;
import daemon.interop.devin.bridge : Bridge;
import daemon.storage : atomicWrite, readJSON;

import std.algorithm : sort;
import std.file : exists, mkdirRecurse;
import std.json : JSONType, JSONValue;
import std.path : buildPath;

private string executionIndexPath(const Bridge owner)
    => buildPath(owner.executionDir, "index.json");

package(daemon.interop.devin) void loadExecutionIndex(Bridge owner)
{
    string path = owner.executionIndexPath();
    if (!exists(path))
        return;

    try
    {
        JSONValue data = readJSON(path, 10 * 1024 * 1024);
        if (data.type != JSONType.object)
            return;

        if ("executions" in data.object && data["executions"].type == JSONType.object)
        {
            foreach (id, item; data["executions"].object)
            {
                if (item.type != JSONType.object)
                    continue;

                JSONValue record = JSONValue.emptyObject;
                record["id"] = JSONValue(id.idup);
                foreach (field; ["sessionId", "createdAt", "finishedAt", "status", "model", "workspace", "mode"])
                {
                    record[field] = field in item.object && item[field].type == JSONType.string
                        ? JSONValue(item[field].str.idup)
                        : JSONValue(null);
                }

                owner.executionRecords[id.idup] = record;
                owner.executionOrder ~= id.idup;
            }
        }

        owner.executionOrder.sort!((left, right) {
            string leftTime = owner.executionRecords[left]["createdAt"].isNull ? "" : owner.executionRecords[left]["createdAt"].str;
            string rightTime = owner.executionRecords[right]["createdAt"].isNull ? "" : owner.executionRecords[right]["createdAt"].str;
            return leftTime == rightTime ? left < right : leftTime < rightTime;
        });
        while (owner.executionOrder.length > owner.maxIndexedExecutions)
        {
            owner.executionRecords.remove(owner.executionOrder[0]);
            owner.executionOrder = owner.executionOrder[1..$];
        }
    }
    catch (Exception)
    {
        // Transcript files remain available if the optional lookup index is damaged.
        owner.executionRecords = null;
        owner.executionOrder = null;
    }
}

private void saveExecutionIndex(Bridge owner)
{
    try
    {
        mkdirRecurse(owner.executionDir);
        JSONValue data = JSONValue.emptyObject;
        data["version"] = JSONValue(1);
        JSONValue execs = JSONValue.emptyObject;
        foreach (id, rec; owner.executionRecords)
            execs[id] = rec;
        data["executions"] = execs;
        atomicWrite(owner.executionIndexPath(), data.toString());
    }
    catch (Exception)
    { }
}

package(daemon.interop.devin) void recordExecution(Bridge owner, Call call)
{
    JSONValue data = call.toJSON();
    JSONValue record = JSONValue.emptyObject;
    foreach (field; ["id", "sessionId", "createdAt", "finishedAt", "status", "model", "workspace", "mode"])
        record[field] = data[field];

    if (call.id !in owner.executionRecords)
    {
        if (owner.executionOrder.length >= owner.maxIndexedExecutions)
        {
            string oldest = owner.executionOrder[0];
            owner.executionOrder = owner.executionOrder[1..$];
            owner.executionRecords.remove(oldest);
        }
        owner.executionOrder ~= call.id;
    }
    owner.executionRecords[call.id] = record;
    owner.saveExecutionIndex();
}

string sessionForExecution(Bridge owner, string id)
{
    if (Call* call = id in owner.executions)
    {
        if ((*call).sessionId.length)
            return (*call).sessionId;
    }
    if (JSONValue* record = id in owner.executionRecords)
        return (*record)["sessionId"].isNull ? null : (*record)["sessionId"].str;

    return null;
}

JSONValue executionRecord(Bridge owner, string id)
{
    if (Call* call = id in owner.executions)
        return (*call).toJSON();

    if (JSONValue* record = id in owner.executionRecords)
        return *record;

    return JSONValue(null);
}
