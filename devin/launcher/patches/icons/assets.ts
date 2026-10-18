import { constants } from "node:fs";
import { open, stat } from "node:fs/promises";
import { dirname, extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const iconByteLimit = 262144;

const imageTypes: Record<string, string> = {
    ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".gif": "image/gif", ".webp": "image/webp", ".ico": "image/x-icon", ".avif": "image/avif",
};

export interface IconAsset
{
    revision: string;
    remote: boolean;
    load(signal: AbortSignal): Promise<string>;
}

function encode(bytes: Buffer, type: string): string
{
    if (!bytes.length || bytes.length > iconByteLimit || !/^image\/[a-z\d.+-]+$/i.test(type))
        throw new Error("Unsupported icon asset.");
    return `data:${type.toLowerCase()};base64,${bytes.toString("base64")}`;
}

function decode(source: string): string
{
    const comma = source.indexOf(",");
    const metadata = source.slice(5, comma).split(";");
    const data = source.slice(comma + 1);
    if (comma < 0 || data.length > iconByteLimit * 4)
        throw new Error("Invalid icon data.");
    let bytes: Buffer;
    if (metadata.some((part) => part.toLowerCase() === "base64"))
    {
        if (!/^(?:[A-Za-z\d+/]{4})*(?:[A-Za-z\d+/]{2}==|[A-Za-z\d+/]{3}=)?$/.test(data))
            throw new Error("Invalid icon encoding.");
        bytes = Buffer.from(data, "base64");
    }
    else
        bytes = Buffer.from(decodeURIComponent(data));
    return encode(bytes, metadata[0] ?? "");
}

async function download(source: string, signal: AbortSignal): Promise<string>
{
    let url = new URL(source);
    for (let redirects = 0; redirects <= 3; redirects++)
    {
        if (!["http:", "https:"].includes(url.protocol) || url.username || url.password)
            throw new Error("Unsupported icon URL.");
        const response = await fetch(url, { redirect: "manual", signal });
        if ([301, 302, 303, 307, 308].includes(response.status))
        {
            await response.body?.cancel();
            const location = response.headers.get("location");
            if (!location || redirects === 3)
                throw new Error("Icon redirect limit exceeded.");
            url = new URL(location, url);
            continue;
        }
        if (!response.ok || Number(response.headers.get("content-length")) > iconByteLimit)
        {
            await response.body?.cancel();
            throw new Error("Icon response rejected.");
        }
        const reader = response.body?.getReader();
        if (!reader)
            throw new Error("Empty icon response.");
        const chunks: Buffer[] = [];
        let length = 0;
        try
        {
            while (true)
            {
                const { value, done } = await reader.read();
                if (done)
                    break;
                length += value.byteLength;
                if (length > iconByteLimit)
                    throw new Error("Icon byte limit exceeded.");
                chunks.push(Buffer.from(value));
            }
        }
        finally
        {
            await reader.cancel();
            reader.releaseLock();
        }
        const type = response.headers.get("content-type")?.split(";", 1)[0]?.trim()
            ?? imageTypes[extname(url.pathname).toLowerCase()] ?? "";
        return encode(Buffer.concat(chunks, length), type);
    }
    throw new Error("Icon redirect limit exceeded.");
}

export async function iconAsset(source: string, registryPath: string): Promise<IconAsset>
{
    if (/^data:/i.test(source))
        return { revision: source, remote: false, load: async () => decode(source) };
    if (/^https?:\/\//i.test(source))
        return { revision: source, remote: true, load: (signal) => download(source, signal) };
    if (/^[a-z][a-z\d+.-]*:/i.test(source) && !/^file:/i.test(source))
        throw new Error("Unsupported icon source.");
    const path = /^file:/i.test(source) ? fileURLToPath(source) : resolve(dirname(registryPath), source);
    const metadata = await stat(path);
    const revision = `${metadata.dev}:${metadata.ino}:${metadata.size}:${metadata.mtimeMs}:${metadata.ctimeMs}`;
    return {
        revision,
        remote: false,
        load: async () =>
        {
            const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
            try
            {
                const opened = await file.stat();
                if (!opened.isFile() || opened.size > iconByteLimit
                    || opened.ino !== metadata.ino || opened.mtimeMs !== metadata.mtimeMs
                    || opened.ctimeMs !== metadata.ctimeMs || opened.size !== metadata.size)
                    throw new Error("Icon file rejected.");
                const bytes = Buffer.alloc(opened.size + 1);
                let length = 0;
                while (length < bytes.length)
                {
                    const read = await file.read(bytes, length, bytes.length - length, length);
                    if (!read.bytesRead)
                        break;
                    length += read.bytesRead;
                }
                const finished = await file.stat();
                if (length !== opened.size || finished.size !== opened.size
                    || finished.mtimeMs !== opened.mtimeMs || finished.ctimeMs !== opened.ctimeMs)
                    throw new Error("Icon file changed during reading.");
                return encode(bytes.subarray(0, length), imageTypes[extname(path).toLowerCase()] ?? "");
            }
            finally
            {
                await file.close();
            }
        },
    };
}
