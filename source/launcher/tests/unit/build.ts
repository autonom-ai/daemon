import {
    DESKTOP_COMMIT,
    DESKTOP_MAIN,
    DESKTOP_VERSION,
    type PackageInfo,
    type PackageLookup,
    verifyDesktopBuild,
    verifyPackageFile,
} from "../../build";

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const WORKBENCH = "out/vs/workbench/workbench.desktop.main.js";
const PACKAGE_ID = "devin-desktop-3.10.67-1.el8.x86_64";
const DISTRO = "f".repeat(64);

function sha256(content: string): string
{
    return createHash("sha256").update(content).digest("hex");
}

async function fixture(files: Record<string, string> = {}): Promise<string>
{
    const app = await mkdtemp(join(tmpdir(), "autonom-build-"));
    const entries: Record<string, string> = {
        "package.json": JSON.stringify({ version: DESKTOP_VERSION, main: DESKTOP_MAIN }),
        "product.json": JSON.stringify({ commit: DESKTOP_COMMIT }),
        "out/main.js": "main bundle",
        [WORKBENCH]: "hot-updated workbench",
        ...files,
    };
    for (const [file, content] of Object.entries(entries))
    {
        const path = join(app, file);
        await mkdir(join(path, ".."), { recursive: true });
        await writeFile(path, content);
    }
    return app;
}

function lookup(app: string, options: {
    algorithm?: number;
    digests?: Record<string, string>;
    links?: Set<string>;
} = {}): PackageLookup
{
    return async (path: string): Promise<PackageInfo | undefined> =>
    {
        if (path !== join(app, "package.json"))
            return undefined;
        const files = new Map(
            ["package.json", "product.json", "out/main.js", WORKBENCH]
                .map((file) => [join(app, file), {
                    digest: options.digests?.[file] ?? sha256(""),
                    linkTo: options.links?.has(file) ? "/elsewhere" : "",
                }]),
        );
        return {
            id: PACKAGE_ID,
            distro: DISTRO,
            digestAlgorithm: options.algorithm ?? 8,
            files,
        };
    };
}

async function genuineLookup(app: string): Promise<PackageLookup>
{
    const digests: Record<string, string> = {};
    for (const file of ["package.json", "product.json", "out/main.js", WORKBENCH])
        digests[file] = sha256(await readFile(join(app, file), "utf8"));
    return lookup(app, { digests });
}

test("a hot-updated workbench verifies through its owning package", async () =>
{
    const app = await fixture();
    try
    {
        const identity = await verifyDesktopBuild(app, await genuineLookup(app));
        assert.equal(identity.source, "package");
        assert.equal(identity.packageId, PACKAGE_ID);
        assert.equal(identity.distro, DISTRO);
        assert.equal(identity.version, DESKTOP_VERSION);
        assert.equal(identity.commit, DESKTOP_COMMIT);
    }
    finally
    {
        await rm(app, { recursive: true, force: true });
    }
});

test("an unowned changed workbench fails closed without a package lookup", async () =>
{
    const app = await fixture();
    try
    {
        await assert.rejects(verifyDesktopBuild(app, async () => undefined), /pristine build/);
    }
    finally
    {
        await rm(app, { recursive: true, force: true });
    }
});

test("changed version, entrypoint, or commit always refuse", async () =>
{
    const app = await fixture();
    try
    {
        const files = { "package.json": "package.json", "product.json": "product.json",
            "out/main.js": "out/main.js", [WORKBENCH]: "workbench" } as const;
        const digests = Object.fromEntries(await Promise.all(Object.keys(files).map(async (file) =>
            [file, sha256(await readFile(join(app, file), "utf8"))])));
        const owned = lookup(app, { digests });
        const metadata = JSON.parse(await readFile(join(app, "package.json"), "utf8"));
        for (const broken of [
            { ...metadata, version: "0.0.0" },
            { ...metadata, main: "./out/other.js" },
        ])
        {
            await writeFile(join(app, "package.json"), JSON.stringify(broken));
            await assert.rejects(verifyDesktopBuild(app, owned), /Unsupported Devin Desktop build/);
        }
        await writeFile(join(app, "package.json"), JSON.stringify(metadata));
        await writeFile(join(app, "product.json"), JSON.stringify({ commit: "0".repeat(40) }));
        await assert.rejects(verifyDesktopBuild(app, owned), /Unsupported Devin Desktop build/);
    }
    finally
    {
        await rm(app, { recursive: true, force: true });
    }
});

test("a non-SHA256 package digest algorithm refuses", async () =>
{
    const app = await fixture();
    try
    {
        await assert.rejects(verifyDesktopBuild(app, lookup(app, { algorithm: 1 })),
            /digest algorithm/);
    }
    finally
    {
        await rm(app, { recursive: true, force: true });
    }
});

test("a file modified after packaging fails the recorded digest", async () =>
{
    const app = await fixture();
    try
    {
        const digests = { [WORKBENCH]: "0".repeat(64) };
        await assert.rejects(verifyDesktopBuild(app, lookup(app, { digests })), /does not match/);
    }
    finally
    {
        await rm(app, { recursive: true, force: true });
    }
});

test("a file outside the owning package refuses", async () =>
{
    const app = await fixture();
    try
    {
        await writeFile(join(app, "out/extra.js"), "foreign");
        const owned = await genuineLookup(app);
        const sha256actual = await verifyPackageFile(join(app, "out/extra.js"), owned);
        assert.equal(sha256actual.expected, null);
        await assert.rejects(verifyDesktopBuild(app, async (path) =>
            path === join(app, "package.json")
                ? { id: PACKAGE_ID, distro: DISTRO, digestAlgorithm: 8, files: new Map() }
                : undefined), /not a regular file shipped/);
    }
    finally
    {
        await rm(app, { recursive: true, force: true });
    }
});

test("a symlinked verified file refuses even when the package records it", async () =>
{
    const app = await fixture();
    try
    {
        const target = join(app, "elsewhere.js");
        await writeFile(target, "foreign");
        await rm(join(app, WORKBENCH));
        await symlink(target, join(app, WORKBENCH));
        await assert.rejects(verifyDesktopBuild(app, await genuineLookup(app)), /regular file|ELOOP/);
    }
    finally
    {
        await rm(app, { recursive: true, force: true });
    }
});

test("package file checks report genuine, foreign, and unowned files", async () =>
{
    const app = await fixture();
    try
    {
        const owned = await genuineLookup(app);
        const main = await verifyPackageFile(join(app, "out/main.js"), owned);
        assert.equal(main.packageId, PACKAGE_ID);
        assert.equal(main.sha256, main.expected);
        const edited = join(app, "product.json");
        await writeFile(edited, "{\"commit\":\"tampered\"}");
        const tampered = await verifyPackageFile(edited, owned);
        assert.notEqual(tampered.sha256, tampered.expected);
        const missing = await verifyPackageFile(join(app, "package.json"), async () => undefined);
        assert.equal(missing.expected, null);
    }
    finally
    {
        await rm(app, { recursive: true, force: true });
    }
});
