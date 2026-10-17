import {
    execute,
    fixture,
    installer,
    originalCli,
    packageUpdate, recordOf,
    sha256,
    track,
    updatedCli
} from "../../install";

import assert from "node:assert/strict";
import { readFile, readdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";

test("an official package update refreshes the tracked generation and archives the previous one", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        const cli = await readFile(join(root, "bin/devin-desktop"));
        await execute("python3", [installer, "--no-build", "--app", app], { env });
        const first = await recordOf(root);
        await packageUpdate(root, updatedCli);
        assert.match((await execute("python3", [installer, "--check", "--app", app], { env })).stdout,
            /official Desktop update|reinstall/);
        await execute("python3", [installer, "--no-build", "--app", app], { env });
        const saved = await recordOf(root);
        assert.equal(saved.version, 2);
        assert.equal((saved.cli as Record<string, unknown>).originalHash, sha256(updatedCli));
        assert.notDeepEqual(saved.build, first.build);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop.autonom.orig")), Buffer.from(updatedCli));
        const archives = await readdir(join(root, "autonom/tracked-builds"));
        assert.equal(archives.length, 1);
        assert.deepEqual(await readFile(join(root, "autonom/tracked-builds", archives[0]!, "devin-desktop.orig")), cli);
        assert.match(await readFile(join(root, "bin/devin-desktop"), "utf8"), /launcher\.js/);
        await execute("python3", [installer, "--uninstall", "--app", app], { env });
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), Buffer.from(updatedCli));
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a package update reverted to the vendor CLI reports pristine without touching files", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await execute("python3", [installer, "--no-build", "--app", app], { env });
        await writeFile(join(root, "bin/devin-desktop"), originalCli, { mode: 0o755 });
        const out = await execute("python3", [installer, "--check", "--app", app], { env });
        assert.match(out.stdout, /verified against package|verified pin/);
        assert.match(out.stdout, /vendor Devin Desktop CLI|wrapper is not active|reinstall/);
        const before = await readFile(join(root, "bin/devin-desktop"));
        await execute("python3", [installer, "--uninstall", "--app", app], { env });
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), before);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("uninstall refuses to restore a stale-generation CLI backup", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await execute("python3", [installer, "--no-build", "--app", app], { env });
        const stub = await readFile(join(root, "bin/devin-desktop"));
        const manifestPath = join(root, "rpm-manifest.json");
        await writeFile(join(app, "out/vs/workbench/workbench.desktop.main.js"), "vendor hot update");
        await track(manifestPath, app, join(root, "bin/devin-desktop"));
        const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
        manifest.files[join(root, "bin/devin-desktop")].digest = sha256(updatedCli);
        await writeFile(manifestPath, JSON.stringify(manifest));
        await assert.rejects(execute("python3", [installer, "--uninstall", "--app", app], { env }),
            /previous Desktop build/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a retained wrapper over a new package refuses to reinstall with a stale backup", async () =>
{
    const { root, app, env, manifestPath } = await fixture();
    try
    {
        await execute("python3", [installer, "--no-build", "--app", app], { env });
        const stub = await readFile(join(root, "bin/devin-desktop"));
        const record = await recordOf(root);
        await writeFile(join(app, "out/vs/workbench/workbench.desktop.main.js"), "vendor hot update");
        await track(manifestPath, app, join(root, "bin/devin-desktop"));
        const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
        manifest.files[join(root, "bin/devin-desktop")].digest = sha256(updatedCli);
        await writeFile(manifestPath, JSON.stringify(manifest));
        await assert.rejects(execute("python3", [installer, "--no-build", "--app", app], { env }),
            /packaged CLI|cannot be proven/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop.autonom.orig")),
            Buffer.from(originalCli));
        assert.deepEqual(await recordOf(root), record);
        await assert.rejects(readdir(join(root, "autonom/tracked-builds")), { code: "ENOENT" });
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a newer package with the same workbench refuses the stale-generation backup", async () =>
{
    const { root, env, manifestPath } = await fixture();
    try
    {
        await execute("python3", [installer, "--no-build", "--app", join(root, "resources/app")], { env });
        const stub = await readFile(join(root, "bin/devin-desktop"));
        const record = await recordOf(root);
        const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
        manifest.distro = "e".repeat(64);
        manifest.files[join(root, "bin/devin-desktop")].digest = sha256(updatedCli);
        await writeFile(manifestPath, JSON.stringify(manifest));
        await assert.rejects(execute("python3", [installer, "--no-build", "--app",
            join(root, "resources/app")], { env }), /packaged CLI|cannot be proven/);
        await assert.rejects(execute("python3", [installer, "--uninstall", "--app",
            join(root, "resources/app")], { env }), /previous Desktop build|cannot be proven/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
        assert.deepEqual(await recordOf(root), record);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});
