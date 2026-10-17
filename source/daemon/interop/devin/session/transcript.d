module daemon.interop.devin.session.transcript;

import daemon.http;
import daemon.interop.call : Call;
import daemon.interop.devin.db : readSessionMessages;
import daemon.interop.devin.history : executionRecord, sessionForExecution;
import daemon.interop.devin.session : Session;
import daemon.interop.devin.session.control : logPath;
import daemon.storage : readText;
static import daemon.api;

import serverino;

import std.file : exists;
import std.json : JSONValue;
import std.path : buildPath;

private void handleTranscript(string id, Output output)
{
    try
    {
        Call execution = daemon.api.bridge.execution(id);
        JSONValue executionJson = execution !is null ? execution.toJSON() : daemon.api.bridge.executionRecord(id);

        string session;
        if (execution !is null && execution.sessionId.length)
            session = execution.sessionId;
        else
        {
            string mapped = daemon.api.bridge.sessionForExecution(id);
            session = mapped.length ? mapped : id;
        }

        string executionOut = buildPath(daemon.api.bridge.executionDir, id~".out");
        string executionErr = buildPath(daemon.api.bridge.executionDir, id~".err");
        bool isKnownExecution = execution !is null || !executionJson.isNull ||
            exists(executionOut) || exists(executionErr);

        bool isKnownSession = session.length && (
            daemon.api.bridge.access.managed(session) ||
            daemon.api.bridge.findSession(session) !is null ||
            exists(daemon.api.bridge.logPath(session))
        );

        if (!isKnownExecution && !isKnownSession)
        {
            respondError(output, 404, "Session is not managed by Autonom");
            return;
        }

        JSONValue ret = JSONValue.emptyObject;
        ret["messages"] = JSONValue.emptyArray;
        ret["execution"] = executionJson.isNull ? JSONValue(null) : executionJson;

        if (session.length && isKnownSession)
        {
            Session found = daemon.api.bridge.findSession(session);
            if (execution is null && found !is null && found.execution !is null)
            {
                execution = found.execution;
                if (ret["execution"].isNull)
                    ret["execution"] = execution.toJSON();
            }

            ret["session"] = found is null ? JSONValue(["id": JSONValue(session)]) : found.toJSON();
            try
                ret["messages"] = readSessionMessages(daemon.api.bridge.sessionDatabase, session);
            catch (Exception)
                ret["messages"] = JSONValue.emptyArray;

            if (!ret["messages"].array.length && exists(daemon.api.bridge.logPath(session)))
            {
                try
                {
                    string sessionLog = readText(daemon.api.bridge.logPath(session), 1024 * 1024);
                    if (sessionLog.length)
                    {
                        ret["messages"].array ~= JSONValue([
                            "role": JSONValue("assistant"),
                            "content": JSONValue(sessionLog)
                        ]);
                    }
                }
                catch (Exception)
                { }
            }
        }
        else
            ret["session"] = JSONValue(null);

        if (!ret["messages"].array.length)
        {
            if (exists(executionOut))
            {
                try
                {
                    string outContent = readText(executionOut, 1024 * 1024);
                    if (outContent.length)
                    {
                        ret["messages"].array ~= JSONValue([
                            "role": JSONValue("assistant"),
                            "content": JSONValue(outContent)
                        ]);
                    }
                }
                catch (Exception)
                { }
            }
            else if (execution !is null && !execution.running && exists(execution.outputPath))
            {
                try
                {
                    string outContent = readText(execution.outputPath, 1024 * 1024);
                    if (outContent.length)
                    {
                        ret["messages"].array ~= JSONValue([
                            "role": JSONValue("assistant"),
                            "content": JSONValue(outContent)
                        ]);
                    }
                }
                catch (Exception)
                { }
            }
        }

        respond(output, ret);
    }
    catch (Exception error)
        respondError(output, 500, error.msg);
}

@endpoint @route!(matchesPath!"/api/executions/<id>/transcript")
void executionTranscript(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    handleTranscript(routeParameter!"/api/executions/<id>/transcript"(request), output);
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/transcript")
void sessionTranscript(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    handleTranscript(routeParameter!"/api/sessions/<id>/transcript"(request), output);
}
