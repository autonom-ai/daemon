import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";

const execute = promisify(execFile);
const installer = resolve(__dirname, "../../../install.sh");
const installedApp = "/usr/share/devin-desktop/resources/app";

async function fixture(): Promise<string>
{
    const ret = await mkdtemp(join(tmpdir(), "autonom-install-"));
    await mkdir(join(ret, "out/vs/workbench"), { recursive: true });
    const metadata = JSON.parse(await readFile(join(installedApp, "package.json"), "utf8"));
    const packageFile = metadata.main === "./out/autonom-bootstrap.mjs" ? "package.json.autonom.orig" : "package.json";
    await copyFile(join(installedApp, packageFile), join(ret, "package.json"));
    for (const file of ["product.json", "out/vs/workbench/workbench.desktop.main.js"])
        await copyFile(join(installedApp, file), join(ret, file));

    return ret;
}

test("installation is idempotent, keeps vendor bundles pristine, and rolls back byte-for-byte", async () =>
{
    const app = await fixture();
    try
    {
        const packagePath = join(app, "package.json");
        const original = await readFile(packagePath);
        const product = await readFile(join(app, "product.json"));
        const bundle = await readFile(join(app, "out/vs/workbench/workbench.desktop.main.js"));
        await execute("bash", [installer, "--no-build", "--app", app]);
        const patched = await readFile(packagePath);
        assert.equal(JSON.parse(patched.toString()).main, "./out/autonom-bootstrap.mjs");
        assert.deepEqual(await readFile(join(app, "package.json.autonom.orig")), original);
        assert.deepEqual(await readFile(join(app, "product.json")), product);
        assert.deepEqual(await readFile(join(app, "out/vs/workbench/workbench.desktop.main.js")), bundle);
        await execute("node", ["--check", join(app, "out/autonom-bootstrap.mjs")]);
        await execute("bash", [installer, "--no-build", "--app", app]);
        assert.deepEqual(await readFile(packagePath), patched);
        assert.match((await execute("bash", [installer, "--check", "--app", app])).stdout, /installed/);
        await execute("bash", [installer, "--uninstall", "--app", app]);
        assert.deepEqual(await readFile(packagePath), original);
        await execute("bash", [installer, "--uninstall", "--app", app]);
        assert.deepEqual(await readFile(packagePath), original);
    }
    finally
    {
        await rm(app, { recursive: true, force: true });
    }
});

test("installer rejects external entrypoint edits rather than overwriting them", async () =>
{
    const app = await fixture();
    try
    {
        await execute("bash", [installer, "--no-build", "--app", app]);
        const packagePath = join(app, "package.json");
        const changed = `${await readFile(packagePath, "utf8")}\n`;
        await writeFile(packagePath, changed);
        await assert.rejects(execute("bash", [installer, "--uninstall", "--app", app]), /changed outside Autonom/);
        assert.equal(await readFile(packagePath, "utf8"), changed);
    }
    finally
    {
        await rm(app, { recursive: true, force: true });
    }
});

test("installer refuses unsupported Desktop builds without creating a backup", async () =>
{
    const app = await fixture();
    try
    {
        const packagePath = join(app, "package.json");
        const metadata = JSON.parse(await readFile(packagePath, "utf8"));
        metadata.version = "0.0.0";
        const changed = JSON.stringify(metadata);
        await writeFile(packagePath, changed);
        await assert.rejects(execute("bash", [installer, "--no-build", "--app", app]), /Unsupported Desktop/);
        assert.equal(await readFile(packagePath, "utf8"), changed);
        await assert.rejects(readFile(join(app, "package.json.autonom.orig")), { code: "ENOENT" });
    }
    finally
    {
        await rm(app, { recursive: true, force: true });
    }
});
