#!/usr/bin/env node
import { createConnection } from "node:net";
import { join } from "node:path";

const USAGE = `Usage: node source/launcher/cdp.mjs <command> [arguments]

Talks to a running Autonom launcher over its private control socket.

Commands:
  status                              Report every attached Devin Desktop window
  targets                             List the renderer targets of the debugging pipe
  eval <target> <expression>          Evaluate an expression in a workbench renderer
  screenshot <target> <file.png>      Capture a renderer screenshot
  hot                                 Reload the Command Center assets and re-attach
  detach                              Restore native Devin Desktop and stop managing

Set AUTONOM_LAUNCHER_SOCKET to override ${defaultSocket()}.`;

function defaultSocket()
{
    const directory = process.env.XDG_RUNTIME_DIR || join(process.env.HOME || "/tmp", ".cache");
    return join(directory, "autonom", "launcher.sock");
}

function request(action, arguments_)
{
    switch (action)
    {
        case "status":
        case "targets":
        case "hot":
        case "detach":
            return { action };
        case "eval":
            if (arguments_.length < 2)
                throw new Error("eval needs a target and an expression.");
            return { action, target: arguments_[0], expression: arguments_.slice(1).join(" ") };
        case "screenshot":
            if (arguments_.length < 2)
                throw new Error("screenshot needs a target and an output path.");
            return { action, target: arguments_[0], path: arguments_[1] };
        default:
            throw new Error(`Unknown command: ${action}`);
    }
}

const [action, ...arguments_] = process.argv.slice(2);
if (!action || action === "--help" || action === "-h")
{
    process.stdout.write(`${USAGE}\n`);
    process.exit(action ? 0 : 1);
}

let message;
try
{
    message = request(action, arguments_);
}
catch (error)
{
    process.stderr.write(`${error.message}\n`);
    process.exit(2);
}

const socketPath = process.env.AUTONOM_LAUNCHER_SOCKET || defaultSocket();
const socket = createConnection(socketPath);
let buffer = "";
socket.setEncoding("utf8");
socket.on("connect", () =>
{
    socket.write(`${JSON.stringify(message)}\n`);
});
socket.on("data", (chunk) =>
{
    buffer += chunk;
    const end = buffer.indexOf("\n");
    if (end < 0)
        return;
    socket.end();
    const response = JSON.parse(buffer.slice(0, end));
    if (response.error)
    {
        process.stderr.write(`${response.error}\n`);
        process.exit(1);
    }
    process.stdout.write(`${JSON.stringify(response.result, null, 2)}\n`);
});
socket.on("error", (error) =>
{
    process.stderr.write(`Cannot reach the Autonom launcher at ${socketPath}: ${error.message}\n`);
    process.exit(1);
});
