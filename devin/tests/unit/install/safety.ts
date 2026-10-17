import {
    execute,
    fixture,
    installer,
    originalCli,
    packageUpdate, recordOf,
    repository,
    updatedCli
} from "../../install";

import assert from "node:assert/strict";
import { chmod, mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";

test("a missing recorded backup refuses install and uninstall before any mutation", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await execute("python3", [installer, "--no-build", "--app", app], { env });
        const stub = await readFile(join(root, "bin/devin-desktop"));
        const record = await recordOf(root);
        await rm(join(root, "bin/devin-desktop.autonom.orig"));
        await assert.rejects(execute("python3", [installer, "--no-build", "--app", app], { env }),
            /backup is missing/);
        await assert.rejects(execute("python3", [installer, "--uninstall", "--app", app], { env }),
            /backup is missing/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
        assert.deepEqual(await recordOf(root), record);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a symlinked install target refuses without writing outside it", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        const outside = join(root, "outside");
        await mkdir(outside);
        await mkdir(join(root, "autonom"), { recursive: true });
        await symlink(outside, join(root, "autonom/bin"));
        await assert.rejects(execute("python3", [installer, "--no-build", "--app", app], { env }),
            /symlinked path/);
        assert.deepEqual(await readdir(outside), []);
        assert.deepEqual(await readdir(join(root, "autonom")), ["bin"]);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), Buffer.from(originalCli));
        await assert.rejects(readFile(join(root, "autonom/install.json")), { code: "ENOENT" });
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a late record write failure restores the CLI, backup, record, and payload", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await execute("python3", [installer, "--no-build", "--app", app], { env });
        const record = await recordOf(root);
        await packageUpdate(root, updatedCli);
        await mkdir(join(root, "autonom/tracked-builds"), { recursive: true });
        await chmod(join(root, "autonom"), 0o555);
        await assert.rejects(execute("python3", [installer, "--no-build", "--app", app], { env }),
            /read-only|Installation failed/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), Buffer.from(updatedCli));
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop.autonom.orig")),
            Buffer.from(originalCli));
        assert.deepEqual(await recordOf(root), record);
        assert.deepEqual(await readdir(join(root, "autonom/tracked-builds")), []);
        assert.deepEqual(await readFile(join(root, "autonom/dist/launcher.js")),
            await readFile(join(repository, "dist/launcher.js")));
        await chmod(join(root, "autonom"), 0o755);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("a failed payload write leaves the CLI and record untouched", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await mkdir(join(root, "autonom"), { recursive: true });
        await writeFile(join(root, "autonom/dist"), "not a directory");
        await assert.rejects(execute("python3", [installer, "--no-build", "--app", app], { env }),
            /Installation failed|read-only/);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), Buffer.from(originalCli));
        await assert.rejects(readFile(join(root, "bin/devin-desktop.autonom.orig")), { code: "ENOENT" });
        await assert.rejects(readFile(join(root, "autonom/install.json")), { code: "ENOENT" });
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("installer rejects external entrypoint edits rather than overwriting them", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        await execute("python3", [installer, "--no-build", "--app", app], { env });
        const entrypoint = join(root, "bin/devin-desktop");
        const changed = `${await readFile(entrypoint, "utf8")}\n`;
        await writeFile(entrypoint, changed);
        await assert.rejects(execute("python3", [installer, "--uninstall", "--app", app], { env }), /changed outside Autonom/);
        await assert.rejects(execute("python3", [installer, "--no-build", "--app", app], { env }), /changed outside Autonom/);
        assert.equal(await readFile(entrypoint, "utf8"), changed);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("installer refuses unsupported Desktop builds without creating a backup", async () =>
{
    const { root, app, env } = await fixture();
    try
    {
        const packagePath = join(app, "package.json");
        const metadata = JSON.parse(await readFile(packagePath, "utf8"));
        metadata.version = "0.0.0";
        const changed = JSON.stringify(metadata);
        await writeFile(packagePath, changed);
        await assert.rejects(execute("python3", [installer, "--no-build", "--app", app], { env }), /Unsupported Devin Desktop build/);
        assert.equal(await readFile(packagePath, "utf8"), changed);
        await assert.rejects(readFile(join(root, "bin/devin-desktop.autonom.orig")), { code: "ENOENT" });
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});
