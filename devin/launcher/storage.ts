import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import type { FileHandle } from "node:fs/promises";
import { lstat, mkdir, open, rename, unlink } from "node:fs/promises";
import { dirname } from "node:path";

export async function readDescriptor(descriptor: FileHandle, limit: number): Promise<string>
{
    const ret = Buffer.alloc(limit + 1);
    let size = 0;
    while (size < ret.length)
    {
        const read = await descriptor.read(ret, size, ret.length - size, null);
        if (!read.bytesRead)
            break;

        size += read.bytesRead;
    }

    if (size > limit)
        throw new Error("File content exceeds the size limit.");

    return ret.subarray(0, size).toString("utf8");
}

export async function readPrivateFile(path: string, limit = 65536): Promise<string>
{
    const descriptor = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try
    {
        const attributes = await descriptor.stat();
        if (!attributes.isFile() || attributes.size > limit)
            throw new Error("Configuration must be a bounded regular file.");

        const ret = await readDescriptor(descriptor, limit);
        if (assetVersion(await descriptor.stat()) !== assetVersion(attributes))
            throw new Error("Configuration changed while being read.");

        return ret;
    }
    finally
    {
        await descriptor.close();
    }
}

export async function writePrivateFile(path: string, content: string): Promise<void>
{
    const parent = dirname(path);
    await mkdir(parent, { recursive: true });
    if ((await lstat(parent)).isSymbolicLink())
        throw new Error("Configuration directory must not be a symlink.");

    const previous = await lstat(path).catch(() => undefined);
    if (previous !== undefined && (!previous.isFile() || previous.isSymbolicLink()))
        throw new Error("Configuration must not be a symlink or special file.");

    const temporary = `${path}.${randomUUID()}.tmp`;
    const descriptor = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
    try
    {
        await descriptor.writeFile(content, "utf8");
        await descriptor.sync();
        await descriptor.close();
        await rename(temporary, path);
    }
    catch (error)
    {
        await descriptor.close().catch(() => undefined);
        await unlink(temporary).catch(() => undefined);
        throw error;
    }
}

export function assetVersion(attributes: { size: number; mtimeMs: number; ctimeMs: number; ino: number }): string
{
    return `${attributes.ino}:${attributes.size}:${attributes.mtimeMs}:${attributes.ctimeMs}`;
}
