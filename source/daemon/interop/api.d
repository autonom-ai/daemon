module daemon.interop.api;

import daemon.api : bridge;
import daemon.http;
import daemon.interop.call : Call;

import serverino;

@endpoint @route!(matchesPath!"/api/executions/<id>")
void getCall(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    Call execution = bridge.execution(routeParameter!"/api/executions/<id>"(request));
    if (execution is null)
        respondError(output, 404, "Call not found");
    else
        respond(output, execution.toJSON());
}

@endpoint @route!(matchesPath!"/api/executions/<id>/stop")
void stopCall(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Post]))
        return;

    Call execution = bridge.execution(routeParameter!"/api/executions/<id>/stop"(request));
    if (execution is null)
    {
        respondError(output, 404, "Call not found");
        return;
    }

    execution.requestStop();
    respond(output, execution.toJSON(), 202);
}
