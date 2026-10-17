import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";

export const desktopVersion = "1.126.0";
export const desktopCommit = "0b186d6e13a1a48a46430c51fe414dd0747d46f6";
export const pinnedWorkbenchHash = "302af387606888341f563bbbac96db129c821602a9fa2bd7f37313899450a6e1";
export const desktopMain = "./out/main.js";

const maxMetadataBytes = 1024 * 1024;
const maxBundleBytes = 64 * 1024 * 1024;
const maxPackageOutputBytes = 32 * 1024 * 1024;
const packageQueryTimeoutMs = 20000;
const sha256DigestAlgorithm = 8;
const workbenchFile = "out/vs/workbench/workbench.desktop.main.js";
const packageFiles = ["package.json", "product.json", "out/main.js", workbenchFile];

export type BuildIdentity = {
    version: string;
    commit: string;
    distro: string;
    workbenchHash: string;
    source: "pin" | "package";
    packageId?: string;
};

export type PackageFile = {
    digest: string;
    linkTo: string;
    config: boolean;
};

export type PackageInfo = {
    id: string;
    distro: string;
    digestAlgorithm: number;
    files: Map<string, PackageFile>;
};

export type PackageLookup = (path: string) => Promise<PackageInfo | undefined>;

export type PackageFileCheck = {
    path: string;
    sha256: string;
    expected: string | null;
    packageId?: string;
    distro?: string;
};

const execute = promisify(execFile);

async function rpmQuery(args: string[]): Promise<string>
{
    const result = await execute("rpm", args, {
        maxBuffer: maxPackageOutputBytes,
        timeout: packageQueryTimeoutMs,
        windowsHide: true,
    });
    return result.stdout;
}

export async function rpmPackageLookup(path: string): Promise<PackageInfo | undefined>
{
    let id: string;
    try
    {
        id = (await rpmQuery(["-qf", "--qf", "%{NEVRA}", "--", path])).trim();
        if (!id || id.includes("\n"))
            return undefined;
    }
    catch
    {
        return undefined;
    }

    const header = await rpmQuery(["-q", "--qf", "%{FILEDIGESTALGO}\n[%{PACKAGEDIGESTALGOS}:%{PACKAGEDIGESTS}\n]", id]);
    const lines = header.split("\n").filter((line) => line.trim());
    const digestAlgorithm = Number(lines[0]);
    const distro = lines.slice(1).find((line) => line.startsWith(`${sha256DigestAlgorithm}:`))
        ?.split(":", 2)[1] ?? "";
    const dump = await rpmQuery(["-q", "--dump", id]);
    const files = new Map<string, PackageFile>();
    for (const line of dump.split("\n"))
    {
        const fields = line.trimEnd().split(" ");
        if (fields.length < 11)
            continue;
        const file = fields.slice(0, -10).join(" ");
        const tail = fields.slice(-10);
        if (file)
            files.set(file, { digest: tail[2]!, linkTo: tail[9] === "X" ? "" : tail[9]!, config: tail[6] === "1" });
    }
    return { id, distro, digestAlgorithm, files };
}

async function fileDigest(path: string, limit: number): Promise<string>
{
    const descriptor = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try
    {
        const attributes = await descriptor.stat();
        if (!attributes.isFile() || attributes.size > limit)
            throw new Error(`${path} is not a bounded regular file.`);
        const hash = createHash("sha256");
        for await (const chunk of descriptor.createReadStream({ autoClose: false }))
            hash.update(chunk as Buffer);
        return hash.digest("hex");
    }
    finally
    {
        await descriptor.close();
    }
}

async function readMetadata(path: string): Promise<Record<string, unknown>>
{
    const descriptor = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try
    {
        const attributes = await descriptor.stat();
        if (!attributes.isFile() || attributes.size > maxMetadataBytes)
            throw new Error("The Desktop build metadata is not a bounded regular file.");
        const parsed: unknown = JSON.parse(await descriptor.readFile("utf8"));
        if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed))
            throw new Error("Invalid Desktop build metadata.");
        return parsed as Record<string, unknown>;
    }
    finally
    {
        await descriptor.close();
    }
}

async function requirePackageFile(info: PackageInfo, path: string,
    mutableConfig = false): Promise<string>
{
    const entry = info.files.get(path);
    if (!entry || entry.linkTo)
        throw new Error(`${path} is not a regular file shipped by ${info.id}.`);
    const actual = await fileDigest(path, maxBundleBytes);
    if (actual !== entry.digest && !(mutableConfig && entry.config))
        throw new Error(`${path} does not match the ${info.id} package digest.`);
    return actual;
}

export async function verifyDesktopBuild(
    appRoot: string,
    lookup: PackageLookup = rpmPackageLookup,
): Promise<BuildIdentity>
{
    const metadata = await readMetadata(join(appRoot, "package.json"));
    const product = await readMetadata(join(appRoot, "product.json"));
    if (metadata.version !== desktopVersion || metadata.main !== desktopMain
        || product.commit !== desktopCommit)
        throw new Error(`Unsupported Devin Desktop build. The Command Center requires version ${desktopVersion} and its pinned commit.`);
    const workbenchHash = await fileDigest(join(appRoot, workbenchFile), maxBundleBytes);
    if (workbenchHash === pinnedWorkbenchHash)
        return { version: desktopVersion, commit: desktopCommit, distro: "", workbenchHash, source: "pin" };
    const info = await lookup(join(appRoot, "package.json"));
    if (!info)
        throw new Error("The native Desktop host bundle is not the verified pristine build. Restore it before launching.");
    if (info.digestAlgorithm !== sha256DigestAlgorithm)
        throw new Error(`Desktop package ${info.id} uses an unsupported file digest algorithm.`);
    for (const file of packageFiles)
        await requirePackageFile(info, join(appRoot, file), file === "product.json");
    return {
        version: desktopVersion,
        commit: desktopCommit,
        distro: info.distro,
        workbenchHash,
        source: "package",
        packageId: info.id,
    };
}

export async function verifyPackageFile(
    path: string,
    lookup: PackageLookup = rpmPackageLookup,
): Promise<PackageFileCheck>
{
    const sha256 = await fileDigest(path, maxBundleBytes);
    const info = await lookup(path);
    if (!info)
        return { path, sha256, expected: null };
    if (info.digestAlgorithm !== sha256DigestAlgorithm)
        throw new Error(`Desktop package ${info.id} uses an unsupported file digest algorithm.`);
    const entry = info.files.get(path);
    const expected = entry && !entry.linkTo ? entry.digest : null;
    return { path, sha256, expected, packageId: info.id, distro: info.distro };
}

export async function main(): Promise<number>
{
    const args = process.argv.slice(2);
    if (args.length === 1 && args[0] !== "--file")
    {
        console.log(JSON.stringify(await verifyDesktopBuild(args[0]!)));
        return 0;
    }
    if (args.length === 2 && args[0] === "--file")
    {
        console.log(JSON.stringify(await verifyPackageFile(args[1]!)));
        return 0;
    }
    console.error("usage: build.js <app> | build.js --file <path>");
    return 2;
}
