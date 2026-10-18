import { CdpClient } from "../launcher/cdp/client";
import { PipeTransport } from "../launcher/cdp/transport";

import { PassThrough } from "node:stream";

export type Request = { id: number; method: string; params: Record<string, any>; sessionId?: string };
type Handler = (request: Request) => unknown;

export function fakeBrowser(handler: Handler): { client: CdpClient; requests: Request[]; emit: (message: unknown) => void }
{
    const readable = new PassThrough();
    const writable = new PassThrough();
    const client = new CdpClient(new PipeTransport(readable, writable));
    const requests: Request[] = [];
    let buffer = "";
    writable.on("data", (chunk: Buffer) =>
    {
        buffer += chunk.toString("utf8");
        let end = buffer.indexOf("\0");
        while (end >= 0)
        {
            const line = buffer.slice(0, end);
            buffer = buffer.slice(end + 1);
            end = buffer.indexOf("\0");
            if (!line)
                continue;
            const request = JSON.parse(line) as Request;
            requests.push(request);
            const reply = handler(request);
            if (reply !== undefined)
                readable.write(`${JSON.stringify(reply)}\0`);
        }
    });
    return {
        client,
        requests,
        emit: (message: unknown) =>
        {
            readable.write(`${JSON.stringify(message)}\0`);
        },
    };
}

export function reply(request: Request, result: Record<string, unknown>): unknown
{
    return { id: request.id, result };
}

export function attach(request: Request): unknown
{
    return request.method === "Target.attachToTarget" ? reply(request, { sessionId: "session-1" }) : undefined;
}

