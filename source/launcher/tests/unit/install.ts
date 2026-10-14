import { resolveDesktopBinary } from "../../desktop";

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";

const execute = promisify(execFile);
const repository = resolve(__dirname, "../../..");
const installer = join(repository, "install.sh");
const installedApp = "/usr/share/devin-desktop/resources/app";

async function fixture(): Promise<string>
{
    const ret = await mkdtemp(join(tmpdir(), "autonom-install-"));
    const app = join(ret, "resources/app");
    await mkdir(join(app, "out/vs/workbench"), { recursive: true });
    await mkdir(join(ret, "bin"));
    await mkdir(join(ret, "usr/bin"), { recursive: true });
    await symlink("../../bin/devin-desktop", join(ret, "usr/bin/devin-desktop"));
    const metadata = JSON.parse(await readFile(join(installedApp, "package.json"), "utf8"));
    const packageFile = metadata.main === "./out/autonom-bootstrap.mjs" ? "package.json.autonom.orig" : "package.json";
    await copyFile(join(installedApp, packageFile), join(app, "package.json"));
    for (const file of ["product.json", "out/main.js", "out/vs/workbench/workbench.desktop.main.js"])
        await copyFile(join(installedApp, file), join(app, file));

    await writeFile(join(ret, "devin-desktop"), "#!/bin/sh\nprintf 'original Desktop\\n'\n", { mode: 0o755 });
    await writeFile(join(ret, "bin/devin-desktop"), "#!/bin/sh\nprintf 'original CLI\\n'\n", { mode: 0o755 });
    return ret;
}

test("installation replaces the CLI entrypoint, keeps app bundles pristine, and rolls back byte-for-byte", async () =>
{
    const root = await fixture();
    const app = join(root, "resources/app");
    try
    {
        const paths = ["package.json", "product.json", "out/main.js", "out/vs/workbench/workbench.desktop.main.js"];
        const originals = await Promise.all(paths.map((file) => readFile(join(app, file))));
        const cli = await readFile(join(root, "bin/devin-desktop"));
        await execute("bash", [installer, "--no-build", "--app", app]);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop.autonom.orig")), cli);
        const stub = await readFile(join(root, "bin/devin-desktop"));
        assert.match(stub.toString(), /exec .*dist\/launcher.js.* "\$@"/);
        assert.equal(resolveDesktopBinary(join(root, "bin/devin-desktop")), join(root, "devin-desktop"));
        for (const file of ["dist/launcher.js", "dist/runtime.js", "assets/ui.yml", "source/launcher/acp/server.py",
            "source/mcp/server.py", "templates/hooks.v1.json", "bin/autonom-daemon"])
            assert.deepEqual(await readFile(join(root, "autonom", file)), await readFile(join(repository, file)));

        await execute("bash", [installer, "--no-build", "--app", app]);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
        assert.match((await execute("bash", [installer, "--check", "--app", app])).stdout, /launcher installed/);
        await execute("bash", [installer, "--uninstall", "--app", app]);
        await execute("bash", [installer, "--uninstall", "--app", app]);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), cli);
        for (let index = 0; index < paths.length; index++)
            assert.deepEqual(await readFile(join(app, paths[index]!)), originals[index]);

        await execute("bash", [installer, "--no-build", "--app", app]);
        assert.deepEqual(await readFile(join(root, "bin/devin-desktop")), stub);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("installed entrypoints preserve argv, cwd, stdout, stderr, and exit status like direct Node", async () =>
{
    const root = await fixture();
    try
    {
        await execute("bash", [installer, "--no-build", "--app", join(root, "resources/app")]);
        const launcher = join(root, "autonom/dist/launcher.js");
        await writeFile(launcher, "console.log(JSON.stringify({arguments:process.argv.slice(2),cwd:process.cwd()}));"
            + "console.error('launcher stderr');process.exitCode=7;\n");
        const arguments_ = ["--debug=9333", "workspace with spaces", "--new-window", "--help"];
        const direct = await execute(process.execPath, [launcher, ...arguments_], { cwd: root })
            .catch((error: { stdout: string; stderr: string; code: number }) => error);
        for (const entrypoint of ["bin/devin-desktop", "usr/bin/devin-desktop"])
        {
            const installed = await execute(join(root, entrypoint), arguments_, { cwd: root })
                .catch((error: { stdout: string; stderr: string; code: number }) => error);
            assert.equal(installed.stdout, direct.stdout);
            assert.equal(installed.stderr, direct.stderr);
            assert.equal("code" in installed && installed.code, 7);
        }
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("installer migrates the package bootstrap back to pristine app startup", async () =>
{
    const root = await fixture();
    const app = join(root, "resources/app");
    try
    {
        const original = await readFile(join(app, "package.json"));
        await copyFile(join(installedApp, "package.json.autonom.orig"), join(app, "package.json.autonom.orig"));
        await copyFile(join(installedApp, "package.json"), join(app, "package.json"));
        await copyFile(join(installedApp, "out/autonom-bootstrap.mjs"), join(app, "out/autonom-bootstrap.mjs"));
        await copyFile(join(installedApp, "out/autonom-install.json"), join(app, "out/autonom-install.json"));
        assert.match((await execute("bash", [installer, "--check", "--app", app])).stdout,
            /CLI launcher upgrade required/);
        await execute("bash", [installer, "--no-build", "--app", app]);
        assert.deepEqual(await readFile(join(app, "package.json")), original);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("installer rejects external entrypoint edits rather than overwriting them", async () =>
{
    const root = await fixture();
    const app = join(root, "resources/app");
    try
    {
        await execute("bash", [installer, "--no-build", "--app", app]);
        const entrypoint = join(root, "bin/devin-desktop");
        const changed = `${await readFile(entrypoint, "utf8")}\n`;
        await writeFile(entrypoint, changed);
        await assert.rejects(execute("bash", [installer, "--uninstall", "--app", app]), /changed outside Autonom/);
        assert.equal(await readFile(entrypoint, "utf8"), changed);
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});

test("installer refuses unsupported Desktop builds without creating a backup", async () =>
{
    const root = await fixture();
    const app = join(root, "resources/app");
    try
    {
        const packagePath = join(app, "package.json");
        const metadata = JSON.parse(await readFile(packagePath, "utf8"));
        metadata.version = "0.0.0";
        const changed = JSON.stringify(metadata);
        await writeFile(packagePath, changed);
        await assert.rejects(execute("bash", [installer, "--no-build", "--app", app]), /Unsupported Desktop/);
        assert.equal(await readFile(packagePath, "utf8"), changed);
        await assert.rejects(readFile(join(root, "bin/devin-desktop.autonom.orig")), { code: "ENOENT" });
    }
    finally
    {
        await rm(root, { recursive: true, force: true });
    }
});
