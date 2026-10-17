import type { Readable, Writable } from "node:stream";

const maxPipeMessageBytes = 32 * 1024 * 1024;

export type CdpTransport = {
    send(message: unknown): void;
    onMessage(listener: (message: unknown) => void): () => void;
    onClose(listener: () => void): () => void;
    close(): void;
};

export class PipeTransport
{
    private buffer = Buffer.alloc(0);
    private readonly listeners = new Set<(message: unknown) => void>();
    private readonly closeListeners = new Set<() => void>();
    private closed = false;

    constructor(private readonly readable: Readable, private readonly writable: Writable)
    {
        readable.on("data", (chunk: Buffer) =>
        {
            this.receive(chunk);
        });
        readable.on("error", () =>
        {
            this.close();
        });
        readable.on("close", () =>
        {
            this.close();
        });
        writable.on("error", () =>
        {
            this.close();
        });
        writable.on("close", () =>
        {
            this.close();
        });
    }

    send(message: unknown): void
    {
        if (this.closed || this.writable.destroyed)
            throw new Error("The Desktop debugging pipe is closed.");
        this.writable.write(`${JSON.stringify(message)}\0`);
    }

    onMessage(listener: (message: unknown) => void): () => void
    {
        this.listeners.add(listener);
        return () =>
        {
            this.listeners.delete(listener);
        };
    }

    onClose(listener: () => void): () => void
    {
        if (this.closed)
            listener();
        else
            this.closeListeners.add(listener);
        return () =>
        {
            this.closeListeners.delete(listener);
        };
    }

    close(): void
    {
        if (this.closed)
            return;
        this.closed = true;
        this.buffer = Buffer.alloc(0);
        this.listeners.clear();
        for (const listener of this.closeListeners)
            listener();
        this.closeListeners.clear();
        this.readable.destroy();
        this.writable.destroy();
    }

    private receive(chunk: Buffer): void
    {
        if (this.closed)
            return;
        this.buffer = Buffer.concat([this.buffer, chunk]);
        if (this.buffer.length > maxPipeMessageBytes)
        {
            this.close();
            return;
        }
        let end = this.buffer.indexOf(0);
        while (end >= 0)
        {
            const message = this.buffer.subarray(0, end).toString("utf8");
            this.buffer = this.buffer.subarray(end + 1);
            end = this.buffer.indexOf(0);
            if (!message)
                continue;
            let parsed: unknown;
            try
            {
                parsed = JSON.parse(message);
            }
            catch
            {
                this.close();
                return;
            }
            for (const listener of this.listeners)
                listener(parsed);
        }
    }
}
