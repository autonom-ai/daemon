module daemon.interop.devin.session.control;

import daemon.exception;
import daemon.http;
import daemon.interop.call : Call, CallKind;
import daemon.interop.devin.bridge : Bridge;
import daemon.interop.devin.calls : newCall;
import daemon.interop.devin.connection;
import daemon.interop.devin.control : controlRequest;
import daemon.interop.devin.session : Session;
import daemon.storage : readText;
static import daemon.api;

import serverino;

import core.thread : Thread;
import std.algorithm : canFind;
import std.file;
import std.json : JSONType, JSONValue;
import std.path : buildPath;

Call remove(Bridge owner, string id)
{
    Session session = owner.session(id);
    if (session.isRunning() && session.execution.kind == CallKind.Remove)
        return session.execution;
    if (owner.observedSession(id) || (!session.isRunning() && owner.online(id)))
        throw new ConflictException("Cannot remove a session owned by another process");

    Call ret = owner.newCall(CallKind.Remove, null, null, session.id);
    owner.launch(ret, null, false, session.execution);
    session.bindCall(ret);
    return ret;
}

Call resumeObserved(
    Bridge owner,
    string id,
    string prompt,
    string directory,
    string model,
    string mode
)
{
    if (!prompt.length || prompt.canFind('\0'))
        throw new InvalidInputException("A prompt is required");
    if (model.canFind('\0'))
        throw new InvalidInputException("Invalid model name");

    string connection = owner.observedConnection(id);
    if (!connection.length)
        throw new ConflictException("Observed session is no longer connected");

    string knownDirectory = owner.observedDirectory(id);
    if (directory.length && knownDirectory.length && directory != knownDirectory)
        throw new InvalidInputException("Directory does not match the observed session");
    if (!knownDirectory.length)
        throw new InvalidInputException("An existing working directory is required");
    directory = knownDirectory;

    Call ret = owner.newCall(CallKind.Resume, directory, model, id);
    ret.mode = mode.idup;
    owner.launch(ret, prompt, false, null, connection);
    owner.session(id).bindCall(ret);
    return ret;
}

void cancelObserved(Bridge owner, string id)
{
    string connection = owner.observedConnection(id);
    if (!connection.length)
        throw new ConflictException("Observed session is no longer connected");

    string socketPath = owner.controlSocket(connection);
    string token = owner.access.clientToken;
    synchronized (owner.controlMutex)
    {
        if (id in owner.cancelling || owner.cancelling.length >= 8)
            return;

        owner.cancelling[id] = true;
    }
    (new Thread({
        try
        {
            controlRequest(socketPath, token, "session/cancel",
                JSONValue(["sessionId": JSONValue(id)]));
        }
        catch (Exception)
        { }
        synchronized (owner.controlMutex)
            owner.cancelling.remove(id);
    })).start();
}

Call steerObserved(Bridge owner, string id, string prompt)
{
    if (!prompt.length || prompt.canFind('\0'))
        throw new InvalidInputException("A prompt is required");

    string connection = owner.observedConnection(id);
    if (!connection.length)
        throw new ConflictException("Observed session is no longer connected");

    Call ret = owner.newCall(CallKind.Resume, owner.observedDirectory(id), null, id);
    owner.launch(ret, prompt, false, null, connection);
    owner.session(id).bindCall(ret);
    return ret;
}

Call steer(Bridge owner, string id, string prompt)
{
    if (!prompt.length || prompt.canFind('\0'))
        throw new InvalidInputException("A prompt is required");

    Session bound = owner.session(id);
    Call active = bound.execution;
    if (active !is null && active.running && active.acceptingSteer)
    {
        if (!active.enqueueSteer(prompt))
            throw new ConflictException("Steering capacity reached");

        return active;
    }
    if (owner.observedSession(id))
        return owner.steerObserved(id, prompt);

    throw new BackendException("Session does not support steering");
}

string logPath(const Bridge owner, string id)
    => buildPath(owner.logDir, id~".log");

void removeLog(Bridge owner, string id)
{
    Session.validateId(id);
    string path = owner.logPath(id);
    if (exists(path))
        std.file.remove(path);
}

private Session lookupSession(string pattern)(Request request, Output output)
{
    Session ret = daemon.api.bridge.findSession(routeParameter!pattern(request));
    if (ret is null)
        respondError(output, 404, "Session not found");

    return ret;
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/resume")
void resumeSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    Launch launch = readLaunch(request);
    string id = routeParameter!"/api/sessions/<id>/resume"(request);
    if (!daemon.api.bridge.access.managed(id) && !daemon.api.bridge.observedSession(id))
        throw new ConflictException("Only sessions started or observed by Autonom may be resumed by Autonom");

    Session session = daemon.api.bridge.session(id);
    if (daemon.api.bridge.observedSession(id))
    {
        if (daemon.api.bridge.observedActive(id))
            throw new ConflictException("Session is already active");
    }
    else if (session.isRunning() || daemon.api.bridge.online(id))
        throw new ConflictException("Session is already active");

    session.resume(
        launch.prompt,
        launch.directory,
        launch.model,
        launch.mode
    );
    respond(output, session.toJSON());
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/steer")
void steerSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    JSONValue data = readBody(request);
    if (data.object.length != 1 || "prompt" !in data.object || data["prompt"].type != JSONType.string)
        throw new InvalidInputException("Expected only the prompt field");

    string id = routeParameter!"/api/sessions/<id>/steer"(request);
    if (!daemon.api.bridge.access.managed(id) && !daemon.api.bridge.observedSession(id))
        throw new ConflictException("Only sessions started or observed by Autonom may be steered");

    Session session = lookupSession!"/api/sessions/<id>/steer"(request, output);
    if (session is null)
        return;

    respond(output, session.steer(data["prompt"].str).toJSON(), 202);
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/stop")
void stopSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    if (readBody(request).object.length != 0)
        throw new InvalidInputException("Expected an empty JSON object");
    Session session = lookupSession!"/api/sessions/<id>/stop"(request, output);
    if (session is null)
        return;

    session.requestStop();
    respond(output, session.toJSON(), 202);
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/log")
void sessionLog(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    Session session = lookupSession!"/api/sessions/<id>/log"(request, output);
    if (session is null)
        return;

    if (!exists(session.logPath))
        respondError(output, 404, "Session log not found");
    else
        respond(output, JSONValue(["log": JSONValue(readText(session.logPath, 1024 * 1024))]));
}

@endpoint @route!(matchesPath!"/api/sessions/<id>/manage")
void manageSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    string id = routeParameter!"/api/sessions/<id>/manage"(request);
    Session.validateId(id);
    daemon.api.bridge.access.remember(id, false);
    respond(output, JSONValue(["id": JSONValue(id), "managed": JSONValue(true)]));
}
