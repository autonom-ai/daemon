import { createHash, randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, rename, unlink } from "node:fs/promises";
import { dirname } from "node:path";

export async function readPrivateFile(path: string, limit = 65536): Promise<string>
{
    const descriptor = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try
    {
        const attributes = await descriptor.stat();
        if (!attributes.isFile() || attributes.size > limit)
            throw new Error("Configuration must be a bounded regular file.");
        return await descriptor.readFile("utf8");
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

export function revision(text: string): string
{
    return createHash("sha256").update(text).digest("hex");
}
